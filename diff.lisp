;;;; diff.lisp - producing unified style diffs from Common Lisp

;;; The diffs generated by this package may not match the diffs
;;; generated by GNU diff (or other diff programs of which I have
;;; not heard).  However, the diffs produced should still apply
;;; cleanly with `patch' or something similar.  If you find files
;;; where this does not hold true, please contact me.
;;;
;;; Differences between line ending conventions are pretty much
;;; ignored in the current implementation, since READ-LINE is used
;;; to snarf the lines from the file.  GNU diff indicates whether
;;; or not the last line in the file ended in a newline; the last
;;; line of our diffs always end in newlines, which may or may not
;;; be acceptable to some people.
;;;
;;; No effort has been made to optimize for speed.  Nonetheless,
;;; the implementation is probably "fast enough", since generating
;;; diffs is not really a speed-critical task.
;;;
;;; Compared to GNU diff, the set of options is pretty small.

(in-package :diff)

(declaim (optimize (debug 3)))


;;; interning arbitrary objects for equality

;;; We've made this fairly general, but we really only use this
;;; machinery to intern strings.  I suppose we could have used CL:INTERN
;;; for this purpose, but I doubt the symbol implementations in a lot
;;; of Common Lisp implementations could handle our requirements.  Plus
;;; it's not clear that symbols are ever garbage-collected.

(defclass interner ()
  ((object-to-code-table :initarg :object-to-code-table
                         :reader object-to-code-table)
   (code-to-object-table :initarg :code-to-object-table
                         :accessor code-to-object-table)
   (last-code :initform 0 :type integer :accessor last-code)))

(defun make-interner (&key (test #'equal))
  (let ((object-to-code-table (make-hash-table :test test))
        (code-to-object-table (make-array 128)))
    (make-instance 'interner :object-to-code-table object-to-code-table
                   :code-to-object-table code-to-object-table)))

(defun interned-object (interner code)
  (aref (code-to-object-table interner) code))

(defun intern-string (interner string)
  (multiple-value-bind (code presentp)
      (gethash string (object-to-code-table interner))
    (if presentp
        code                            ; string already exists
        (let ((object-code (last-code interner))
              (otc-table (object-to-code-table interner))
              (cto-table (code-to-object-table interner)))
          ;; grow table if necessary
          (when (= object-code (length cto-table))
            (let ((new-cto-table (make-array (* (length cto-table) 2))))
              (replace new-cto-table cto-table)
              (setf cto-table new-cto-table)
              (setf (code-to-object-table interner) new-cto-table)))
          (setf (gethash string otc-table) object-code
                (aref cto-table object-code) string)
          (incf (last-code interner))
          object-code))))

(defmacro do-stream-lines ((line-var stream-var &optional result) &body body)
  `(loop for ,line-var = (read-line ,stream-var nil nil)
         while ,line-var
         do ,@body
         finally (return ,result)))

(defmacro do-file-lines ((line-var pathname-var &optional result) &body body)
  (let ((stream-var (gensym)))
    `(with-open-file (,stream-var ,pathname-var :direction :input
                      :element-type 'character)
      (do-stream-lines (,line-var ,stream-var ,result)
        ,@body))))

(defun intern-files (&rest files)
  "Returns values of an interner and list of interned-files"
  (let ((interner (make-interner))
        (interned-files nil))
    (dolist (file files 
             (values interner (nreverse interned-files)))
      (let ((interned-file nil))
        (do-file-lines (line file)
          (let ((code (intern-string interner line)))
            (push code interned-file)))
        (push (coerce (nreverse interned-file) 'simple-vector) interned-files)))))

;;; Computing longest common subsequences between two sequences whose
;;; elements compare equal via EQL.  The algorithm used here is based
;;; on _An O(NP) Sequence Comparison Algorithm_ by Sun Wu, Udi Manber,
;;; and Gene Meyers.

(defclass snake ()
  ((original-offset :accessor original-offset :initarg :original-offset)
   (modified-offset :accessor modified-offset :initarg :modified-offset)
   (length :accessor snake-length :initarg :length)
   (lcs :accessor lcs :initform nil)))

(defmethod print-object ((snake snake) stream)
  (print-unreadable-object (snake stream)
    (format stream "Snake ~A ~A ~A" 
            (original-offset snake)
            (modified-offset snake)
            (snake-length snake))))

(defun snake (lcs original modified k y)
  (let* ((x (- y k))
         (y y)
         (x-start x)
         (y-start y))
    (loop while (and (< -1 x (length original))
                     (< -1 y (length modified))
                     (eql (svref original x) (svref modified y)))
      do (incf x) (incf y))
    (let ((snake (make-instance 'snake
                                :original-offset x-start
                                :modified-offset y-start
                                :length (- y y-start))))
      (if (= y-start y)
          (setf (lcs snake) lcs)
          (setf (lcs snake) (cons snake lcs)))
      snake)))

(defun modified-end (snake)
  (+ (modified-offset snake) (snake-length snake)))

(defun compute-lcs* (original modified)
  (let* ((m (length original))
         (n (length modified))
         (fp (make-array (+ m n 3)
                         :initial-element (make-instance 'snake
                                                         :original-offset -1
                                                         :modified-offset -1
                                                         :length 0)))
         (delta (- n m)))
    ;; There ought to be a good way to let the lengths be arbitrary,
    ;; but right now, we're just going to enforce that the modified
    ;; always be longer and let the caller do the fixing if need be.
    (when (minusp delta)
      (error "Length of MODIFIED less than length of ORIGINAL."))
    (macrolet ((fpref (index)
                 `(svref fp (+ ,index m 1))))
      (flet ((do-snake (index)
               ;; ugh, FIXME
               (let ((snake (let ((lower-snake (fpref (1- index)))
                                  (upper-snake (fpref (1+ index))))
                              (if (> (1+ (modified-end lower-snake))
                                     (modified-end upper-snake))
                                  (snake (lcs lower-snake)
                                         original modified index
                                         (1+ (modified-end lower-snake)))
                                  (snake (lcs upper-snake)
                                         original modified index
                                         (modified-end upper-snake))))))
                 (setf (fpref index) snake))))
        (do ((p 0 (1+ p)))
            ((= (modified-end (fpref delta)) n)
             ;; Add one last snake to easily detect EOF.
             (nreverse (cons (make-instance 'snake :original-offset m
                                            :modified-offset n
                                            :length 0)
                             (lcs (fpref delta)))))
          (loop for k from (- p) upto (1- delta)
                do (do-snake k))
          (loop for k from (+ delta p) downto (1+ delta)
                do (do-snake k))
          (do-snake delta))))))

(defun compute-lcs (original modified)
  (let* ((original-length (length original))
         (modified-length (length modified))
         (modified-longer-p (> modified-length original-length))
         ;; The algorithm given in the paper only works when the
         ;; modified is at least as long as the original.  So we let
         ;; the algorithm follow that assumption and then fix it
         ;; at a later point.  The lcs between two originals is
         ;; always the same--but the *diff* between them will be
         ;; different depending on the ordering.
         (lcs (if modified-longer-p
                  (compute-lcs* original modified)
                  (compute-lcs* modified original))))
    (unless modified-longer-p
      ;; Go through and fix the lcs to have the right references.
      (dolist (snake lcs)
        (rotatef (original-offset snake) (modified-offset snake))))
    lcs))

;;; actually producing diffs from longest common subsequences

(defclass diff-region ()
  ((original-start :initarg :original-start :reader original-start)
   (original-length :initarg :original-length :reader original-length)
   (modified-start :initarg :modified-start :reader modified-start)
   (modified-length :initarg :modified-length :reader modified-length)))

(defclass common-diff-region (diff-region) ())

(defclass modified-diff-region (diff-region) ())

(defmethod print-object ((diff-region diff-region) stream)
  (print-unreadable-object (diff-region stream)
    (format stream "~A src:~A/~A mod:~A/~A"
            (class-name (class-of diff-region))
            (original-start diff-region) (original-length diff-region)
            (modified-start diff-region) (modified-length diff-region))))

(defun convert-lcs-to-diff (lcs &key (want-common t)
                                (original-start 0)
                                (modified-start 0))
  (let ((diff-regions nil))
    (loop
        (let ((snake (first lcs)))
          (when (or (< original-start (original-offset snake))
                    (< modified-start (modified-offset snake)))
            (push (make-instance 'modified-diff-region
                                 :original-start original-start
                                 :original-length (- (original-offset snake)
                                                   original-start)
                                 :modified-start modified-start
                                 :modified-length (- (modified-offset snake)
                                                   modified-start))
                  diff-regions))
          (when (zerop (snake-length snake))
            ;; Party's over, let's go home.
            (return-from convert-lcs-to-diff (nreverse diff-regions)))
          (setf original-start (original-offset snake)
                modified-start (modified-offset snake))
          (when want-common
            (push (make-instance 'common-diff-region
                                 :original-start original-start
                                 :original-length (snake-length snake)
                                 :modified-start modified-start
                                 :modified-length (snake-length snake))
                  diff-regions))
          (incf original-start (snake-length snake))
          (incf modified-start (snake-length snake))
          (pop lcs)))))

(defun compute-raw-diff (origin modified)
  (convert-lcs-to-diff (compute-lcs origin modified)))


;;; producing diffs in "unified diff" format

(defparameter *diff-context-lines* 3
  "The number of lines of context to include for unified and context style
diffs.  The 'patch' program will have a hard time with less than two lines
of context; the default of three should be good enough for most situations.")

(defclass diff ()
  ((original-pathname :initarg :original-pathname :accessor original-pathname)
   (modified-pathname :initarg :modified-pathname :accessor modified-pathname)
   (window-class :initarg :window-class :reader diff-window-class)
   (windows :initform nil :accessor diff-windows)))

(defclass unified-diff (diff) ()
  (:default-initargs
   :window-class 'unified-diff-window))

(defclass context-diff (diff) ()
  (:default-initargs
   :window-class 'context-diff-window))

(defclass diff-generator ()
  ((interned-lines :initarg :interned-lines :reader interner)
   (original-lines :initarg :original-lines :reader original-lines)
   (modified-lines :initarg :modified-lines :reader modified-lines)
   (current-window :initform nil :accessor current-window)
   (diff :initarg :diff :reader diff)))

(defun original-line (context index)
  (let ((interner (interner context))
        (original-lines (original-lines context)))
    (interned-object interner (aref original-lines index))))

(defun modified-line (context index)
  (let ((interner (interner context))
        (modified-lines (modified-lines context)))
    (interned-object interner (aref modified-lines index))))

;;; Some other diff implementations call this a "hunk".
(defclass diff-window ()
  ((original-start-line :initarg :original-start-line
                        :accessor original-start-line)
   (modified-start-line :initarg :modified-start-line
                        :accessor modified-start-line)
   (original-length :initarg :original-length
                    :initform 0
                    :accessor original-length)
   (modified-length :initarg :modified-length
                    :initform 0
                    :accessor modified-length)
   (window-chunks :initform nil
                  :accessor window-chunks)))

(deftype chunk-kind () '(member :common :delete :replace :insert :create))

(defclass chunk ()
  ((kind :initarg :kind :reader chunk-kind :type chunk-kind)
   (lines :initarg :lines :reader chunk-lines :type list)))

(defun modified-chunk-p (chunk)
  (let ((kind (chunk-kind chunk)))
    (or (eq kind :insert) (eq kind :create))))

(defun original-chunk-p (chunk)
  (let ((kind (chunk-kind chunk)))
    (or (eq kind :delete) (eq kind :replace))))

(defmethod print-object ((object chunk) stream)
  (print-unreadable-object (object stream)
    (format stream "Chunk ~A / ~A" (chunk-kind object)
            (length (chunk-lines object)))))

(defclass unified-diff-window (diff-window) ())
(defclass context-diff-window (diff-window) ())

(defun create-window (generator)
  (create-window-for-diff (diff generator)))

(defun create-window-for-diff (diff)
  (make-instance (diff-window-class diff)))

(defun original-window-length (window)
  (reduce #'+ (window-chunks window)
          :key #'(lambda (chunk)
                   (ecase (chunk-kind chunk)
                     ((:common :delete :replace) (length (chunk-lines chunk)))
                     ((:insert :create) 0)))
          :initial-value 0))

(defun modified-window-length (window)
  (reduce #'+ (window-chunks window)
          :key #'(lambda (chunk)
                   (ecase (chunk-kind chunk)
                     ((:common :insert :create) (length (chunk-lines chunk)))
                     ((:delete :replace) 0)))
          :initial-value 0))

(defun add-window (context window)
  (setf (window-chunks window) (nreverse (window-chunks window)))
  (push window (diff-windows (diff context)))
  (setf (current-window context) nil))

(defgeneric process-region (context region))

(defun last-region-p (context region)
  (and (= (length (original-lines context))
          (+ (original-start region) (original-length region)))
       (= (length (modified-lines context))
          (+ (modified-start region) (modified-length region)))))

(defmethod process-region ((context diff-generator)
                           (region common-diff-region))
  (when (current-window context)
    (do ((i 0 (1+ i))
         (common-lines nil))
        ;; I'm not entirely convinced that this is right, but the logic
        ;; embodied in this complicated expression can be summarized
        ;; as follows:
        ;;
        ;; * if this is the last region in the diff, then we should
        ;;   only add a few lines of context;
        ;; * if this is a "large" region, then we should only add a
        ;;   few lines of context
        ;; * otherwise, we have a "small" connecting region and we
        ;;   should attempt to add the entire thing.
        ((or (if (or (> (original-length region)
                        (* *diff-context-lines* 2))
                     (last-region-p context region))
                 (= i *diff-context-lines*)
                 (= i (* *diff-context-lines* 2)))
             (= i (original-length region)))
         ;; Add the lines to the current window.
         (push (make-instance 'chunk
                              :kind :common
                              :lines (nreverse common-lines))
               (window-chunks (current-window context)))
         ;; If this is the last chunk of common lines to add, then we
         ;; need to reverse the chunks of lines in the window, add
         ;; the current window to the window list and null out the
         ;; current window.
         (when (> (original-length region)
                  (* *diff-context-lines* 2))
           (add-window context (current-window context))))
      (push (original-line context (+ i (original-start region)))
            common-lines))))

(defmethod process-region ((context diff-generator)
                           (region modified-diff-region))
  (let ((window (current-window context)))
    (unless window
      ;; This is the ugly case, because there was some common region
      ;; which we don't know about, yet we have to add lines from said
      ;; region.  We do know, however, that the common region which
      ;; preceeded this one must have been longer than
      ;; *DIFF-CONTEXT-LINES* lines, or else the window would not
      ;; be NIL.  We therefore walk backwards from ourself, adding
      ;; common lines as we go, and then we add the lines we contribute.
      (do ((i 0 (1+ i))
           (new-window (create-window context))
           (common-lines nil))
          ((or (= i *diff-context-lines*)
               ;; Edge case of when the common region begins the file
               ;; and is quite small.
               (= 0 (- (original-start region) i)))
           (push (make-instance 'chunk
                                :kind :common
                                :lines common-lines)
                 (window-chunks new-window))
           ;; Make a note of where this window started for posterity.
           (setf (original-start-line new-window) (- (original-start region) i)
                 (modified-start-line new-window) (- (modified-start region) i))
           (setf (current-window context) new-window)
           (setf window new-window))
        (push (original-line context (- (original-start region) i 1))
              common-lines)))
    ;; Deletes come first.
    (when (plusp (original-length region))
      (loop for index from (original-start region)
            below (+ (original-start region) (original-length region))
            collect (original-line context index) into deleted-lines
            finally (push (make-instance 'chunk
                                         :kind (if (plusp (modified-length region))
                                                   :replace
                                                   :delete)
                                         :lines deleted-lines)
                          (window-chunks window))))
    ;; Now for the inserts.
    (when (plusp (modified-length region))
      (loop for index from (modified-start region)
            below (+ (modified-start region) (modified-length region))
            collect (modified-line context index) into inserted-lines
            finally (push (make-instance 'chunk
                                         :kind (if (plusp (original-length region))
                                                   :insert
                                                   :create)
                                         :lines inserted-lines)
                          (window-chunks window))))))

;;; Actually producing diffs.
(defun walk-diff-regions (context diff-regions)
  (declare (type diff-generator context))
  (declare (type list diff-regions))
  (dolist (region diff-regions)
    (process-region context region))
  ;; Pick off any stragglers.  FIXME: is this appropriate for a generic
  ;; operation like WALK-DIFF-REGIONS?  Maybe there should be a function
  ;; like FINALIZE-CONTEXT or some such.
  (when (current-window context)
    (add-window context (current-window context)))
  (let ((diff (diff context)))
    (setf (diff-windows diff) (nreverse (diff-windows diff)))
    diff))

(defun create-diff-generator (diff-kind interner
                                      original-pathname original-lines
                                      modified-pathname modified-lines)
  (make-instance 'diff-generator
                 :interned-lines interner
                 :original-lines original-lines
                 :modified-lines modified-lines
                 :diff (make-instance diff-kind
                                      :original-pathname original-pathname
                                      :modified-pathname modified-pathname)))

(defgeneric render-diff (diff stream)
  (:documentation "Print DIFF object to STREAM"))

(defgeneric render-diff-window (window stream)
  (:documentation "Print WINDOW to STREAM"))

(defun generate-diff (diff-kind original-pathname modified-pathname)
  "Returns diff object between ORIGINAL-PATHNAME and MODIFIED-PATHNAME.
DIFF-KIND should be the symbol DIFF:UNIFIED-DIFF or DIFF:CONTEXT-DIFF."
  (multiple-value-bind (interner interned-files)
      (intern-files original-pathname modified-pathname)
    (let* ((original (first interned-files))
           (modified (second interned-files))
           (lcs (compute-lcs original modified)))
      (let ((diff-regions (convert-lcs-to-diff lcs))
            (context (create-diff-generator diff-kind interner
                                            original-pathname original
                                            modified-pathname modified)))
        (walk-diff-regions context diff-regions)))))

(defun format-diff (diff-kind original-pathname modified-pathname &optional (stream *standard-output*))
  "Output stream for diff between ORIGINAL-PATHNAME and MODIFIED-PATHNAME.
DIFF-KIND should be the symbol DIFF:UNIFIED-DIFF or DIFF:CONTEXT-DIFF."
  (render-diff (generate-diff diff-kind
                              original-pathname
                              modified-pathname)
               stream))

(defun format-diff-string (diff-kind original-pathname modified-pathname)
  "Returns string of diff between ORIGINAL-PATHNAME and MODIFIED-PATHNAME.
DIFF-KIND should be the symbol DIFF:UNIFIED-DIFF or DIFF:CONTEXT-DIFF."
  (with-output-to-string (out)
    (format-diff diff-kind original-pathname modified-pathname out)))

;;; printing diffs on streams


(defmethod render-diff-window :before ((window unified-diff-window) stream)
  (let ((original-length (original-window-length window))
        (modified-length (modified-window-length window)))
    (format stream "@@ -~A" (1+ (original-start-line window)))
    (unless (zerop original-length)
      (format stream ",~A" original-length))
    (format stream " +~A" (1+ (modified-start-line window)))
    (unless (zerop modified-length)
      (format stream ",~A" modified-length))
    (write-string " @@" stream)
    (terpri stream)))

(defmethod render-diff-window :before ((window context-diff-window) stream)
  (format stream "***************~%"))

(defmethod render-diff-window ((object unified-diff-window) stream)
  (dolist (chunk (window-chunks object))
    (let ((prefix (ecase (chunk-kind chunk)
                    (:common #\Space)
                    ((:delete :replace) #\-)
                    ((:insert :create) #\+))))
      (dolist (line (chunk-lines chunk))
        (write-char prefix stream)
        (write-string line stream)
        (terpri stream)))))

(defun window-contains-deletes-p (window)
  (some #'original-chunk-p (window-chunks window)))

(defun window-contains-inserts-p (window)
  (some #'modified-chunk-p (window-chunks window)))

(defmethod render-diff-window ((window context-diff-window) stream)
  (let ((original-length (1- (original-window-length window)))
        (original-start-line (1+ (original-start-line window)))
        (modified-length (1- (modified-window-length window)))
        (modified-start-line (1+ (modified-start-line window))))
    ;; FIXME: lots of duplicated code, but factoring it out would result
    ;; in a function with about ten parameters...which is of dubious
    ;; usefulness.  Still, good style dictates that it should be done.
    ;; the original file comes first
    (format stream "*** ~A,~A ****~%" original-start-line
            (+ original-start-line original-length))
    (when (and (plusp original-length) (window-contains-deletes-p window))
      (dolist (chunk (window-chunks window))
        (unless (modified-chunk-p chunk)
          (let ((prefix (ecase (chunk-kind chunk)
                          (:common #\Space)
                          (:replace #\!)
                          (:delete #\-))))
            (dolist (line (chunk-lines chunk))
              (write-char prefix stream)
              (write-string line stream)
              (terpri stream))))))
    ;; now the modified file
    (format stream "--- ~A,~A ----~%" modified-start-line
            (+ modified-start-line modified-length))
    (when (and (plusp modified-length) (window-contains-inserts-p window))
      (dolist (chunk (window-chunks window))
        (unless (original-chunk-p chunk)
          (let ((prefix (ecase (chunk-kind chunk)
                          (:common #\Space)
                          (:insert #\!)
                          (:create #\+))))
            (dolist (line (chunk-lines chunk))
              (write-char prefix stream)
              (write-string line stream)
              (terpri stream))))))))

(defmethod render-diff :before ((diff unified-diff) stream)
  (format stream "--- ~A~%+++ ~A~%"
          (namestring (original-pathname diff))
          (namestring (modified-pathname diff))))

(defmethod render-diff :before ((diff context-diff) stream)
  (format stream "*** ~A~%--- ~A~%"
          (namestring (original-pathname diff))
          (namestring (modified-pathname diff))))

(defmethod render-diff ((object diff) stream)
  (dolist (window (diff-windows object))
    (render-diff-window window stream)))

