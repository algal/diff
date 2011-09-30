;;;; package.lisp

(defpackage :diff
  (:use :cl)
  (:export #:*diff-context-lines*
           #:generate-diff
           #:unified-diff #:context-diff
           
           #:render-diff
           #:render-diff-window
           #:format-diff
           #:format-diff-string

           #:diff
           #:original-pathname
           #:modified-pathname
           #:diff-window-class
           #:diff-windows

           #:diff-window
           #:original-start-line
           #:original-length
           #:modified-start-line
           #:modified-length
           #:window-chunks

           #:chunk-kind
           #:chunk-lines

           #:compute-raw-diff
           #:common-diff-region
           #:modified-diff-region
           #:original-start
           #:original-length
           #:modified-start
           #:modified-length)
  (:documentation 
   "DIFF is a package for computing various forms of differences between
blobs of data and then doing neat things with those differences.
Currently diff knows how to compute three common forms of differences:

* \"unified\" format diffs, suitable for inspecting changes between
  different versions of files;
* \"context\" format diffs, suitable for inspecting changes between
  different versions of files;
* \"vdelta\" format binary diffs, which might be useful in a version
  control system for compact storage of deltas.

An ASDF system is provided; there are no symbols exported from the DIFF
package, as a good interface has not yet been decided upon.
Documentation is fairly sparse.

Nathan Froyd <froydnj@gmail.com>"))
