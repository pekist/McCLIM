;;; -*- Mode: Lisp; Package: CLIM-INTERNALS -*-

;;;  (c) copyright 2001 by Alexey Dejneka (adejneka@comail.ru)

;;; This library is free software; you can redistribute it and/or
;;; modify it under the terms of the GNU Library General Public
;;; License as published by the Free Software Foundation; either
;;; version 2 of the License, or (at your option) any later version.
;;;
;;; This library is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;; Library General Public License for more details.
;;;
;;; You should have received a copy of the GNU Library General Public
;;; License along with this library; if not, write to the
;;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;;; Boston, MA  02111-1307  USA.

;;; TODO:
;;;
;;; - Check types: RATIONAL, COORDINATE, REAL?
;;; - Check default values of unsupplied arguments.
;;; - Better error detection.
;;; - 
;;; - Multiple columns:
;;; - - all columns are assumed to have the same width;
;;; - - all columns have the same number of rows; they should have the
;;;     same height.
;;; - :MOVE-CURSOR T support.
;;; - All types of spacing, widths, heights.
;;; - FIXMEs.
;;; - Bug: only one option of :X-SPACING and :Y-SPACING works now. (?)
;;; - Item list formatting: what is :EQUALIZE-COLUMN-WIDTHS?!

(in-package :CLIM-INTERNALS)

;;; Space specification parsing
#+ignore(deftype space () 'real)
;; There is spacing-value in panes.lisp now --GB 2002-08-14

(defun parse-space (stream specification direction)
  "Returns the amount of space given by SPECIFICATION relating to the
STREAM in the direction DIRECTION."
  ;; This implementation lives unter the assumption that an
  ;; extended-output stream is also a sheet and has a graft. 
  ;; --GB 2002-08-14
  (etypecase specification
    (integer specification)
    ((or string character) (multiple-value-bind (width height)
                               (text-size stream specification)
                             (ecase direction
                               (:horizontal width)
                               (:vertical height))))
    (function (let ((record (with-output-to-output-record (stream)
                              (funcall specification))))
                (ecase direction
                  (:horizontal (bounding-rectangle-width record))
                  (:vertical (bounding-rectangle-height record)))))
    ((cons real (cons (member :character) null))
     (stream-character-width stream #\M))
    ((cons real (cons (member :line) null))
     (stream-line-height stream))
    ((cons real (cons (member :point :pixel :mm) null))
     (let* ((value (car specification))
            (unit  (cadr specification))
            (graft (graft stream))
            (gunit (graft-units graft)))
       ;; mungle specification into what grafts talk about
       (case unit
         ((:point)  (setf value (/ value 72) unit :inch))
         ((:pixels) (setf unit :device))
         ((:mm)     (setf unit :millimeters)))
       ;; 
       (multiple-value-bind (dx dy)
           (multiple-value-call
               #'transform-distance (compose-transformation-with-scaling
                                     (sheet-delta-transformation stream graft)
                                     (/ (graft-width graft :units unit)
                                        (graft-width graft :units gunit))
                                     (/ (graft-height graft :units unit)
                                        (graft-height graft :units gunit)))
               (ecase direction
                 (:horizontal (values 1 0))
                 (:horizontal (values 0 1))))
         (/ value (sqrt (+ (* dx dx) (* dy dy)))))))))



;;; Cell formatting
(defclass cell-output-record (output-record)
  ()
  (:documentation "The protocol class representing one cell in a table
or an item list."))

(defun cell-output-record-p (object)
  (typep object 'cell-output-record))

(defgeneric adjust-cell* (cell x y width height)
  (:documentation "Fits the cell in the rectangle."))

(defmethod adjust-cell* ((cell cell-output-record) x y width height)
  (declare (type real x y width height))
  (multiple-value-bind (left top right bottom) (bounding-rectangle* cell)
    (let ((dx (ecase (cell-align-x cell)
                (:left (- x left))
                (:right (- (+ x width) right))
                (:center (+ x (/ (- width right left) 2)))))
          (dy (ecase (cell-align-y cell)
                ;; (:baseline) FIXME!!! Not implemented.
                (:bottom (- (+ y height) bottom))
                (:top (- y top))
                (:center (+ y (/ (- height top bottom) 2))))))
      (multiple-value-bind (cell-x cell-y) (output-record-position cell)
        (setf (output-record-position cell)
              (values (+ cell-x dx) (+ cell-y dy)))))))

;;; STANDARD-CELL-OUTPUT-RECORD class
(defclass standard-cell-output-record (cell-output-record
                                       standard-sequence-output-record)
  ((align-x :initform nil :initarg :align-x :reader cell-align-x)
   (align-y :initform nil :initarg :align-y :reader cell-align-y)
   (min-width :initform 0 :initarg :min-width :reader cell-min-width)
   (min-height :initform 0 :initarg :min-height :reader cell-min-height)))

(defmethod initialize-instance :after ((cell standard-cell-output-record)
                                       &rest args)
  (declare (ignore args))
  (with-slots (align-x align-y) cell
    (orf align-x :left)
    (orf align-y :bottom))) ; FIXME: :BASELINE

(defmacro formatting-cell ((&optional (stream t)
                            &key align-x align-y
                                 min-width min-height
                                 (record-type ''standard-cell-output-record))
                           &body body)
  (check-type stream symbol)
  (when (eq stream 't)
    (setq stream '*standard-output*))
  (with-gensyms (record parent)
    `(progn
       (let ((,parent (stream-current-output-record ,stream)))
         (assert (or (row-output-record-p ,parent)
                     (column-output-record-p ,parent)
                     (item-list-output-record-p ,parent))))
       (with-new-output-record (,stream ,record-type ,record
                                :align-x ,align-x :align-y ,align-y
                                :min-width (parse-space ,stream
                                                        (or ,min-width 0)
                                                        :horizontal)
                                :min-height (parse-space ,stream
                                                         (or ,min-height 0)
                                                         :vertical))
         (declare (ignore ,record))
         (letf (((stream-cursor-position ,stream) (values 0 0)))
           ,@body)))))



;;; Generic block formatting
(defclass block-output-record (output-record)
  ()
  (:documentation "The class representing one-dimensional blocks of cells."))

(defgeneric map-over-block-cells (function block)
  (:documentation "Applies the FUNCTION to all cells in the BLOCK."))

(defgeneric cell-common-size (cell block)
  (:documentation "Returns the size of the CELL which corresponds to
the common dimension of all cells in the BLOCK."))

(defgeneric cell-size (cell block)
  (:documentation "Returns the size of the CELL which corresponds to
the individual dimensions of cells in the BLOCK. "))

(defgeneric block-adjust-cell* (cell block
                                cell-coordinate common-coordinate
                                size common-size)
  (:documentation "Fits the CELL of the BLOCK in the rectangle."))

(defclass block-info ()
  ((common-size :type real
                :initform 0
                :accessor block-info-common-size)
   (number-of-cells :type integer
                    :initform 0
                    :accessor block-info-number-of-cells)
   (cell-sizes :type list
               :initform nil
               :accessor block-info-cell-sizes)))

(defun block-info (block)
  "Returns information about the BLOCK in struct BLOCK-INFO."
  (declare (type block-output-record block))
  (let ((info (make-instance 'block-info)))
    (with-slots (common-size number-of-cells cell-sizes) info
      (map-over-block-cells
       (lambda (cell)
         (setf common-size
               (max (cell-common-size cell block) common-size))
         (incf number-of-cells)
         (push (cell-size cell block) cell-sizes))
       block)
      (setf cell-sizes (nreverse cell-sizes)))
    info))

(defun adjust-block (block sizes spacing common-coordinate common-size)
  "Adjusts cells of the BLOCK. SIZES is a vector of new sizes of the
of the cells in the BLOCK. SPACING is a space between cells. The BLOCK
will start at COMMON-COORDININATE and will have COMMON-SIZE on common
dimension."
  (declare (type block-output-record block)
           (type (vector real) sizes)
           (type real common-coordinate common-size))
  (let ((cell-coordinate 0)
        (cell-number 0))
    (map-over-block-cells
     (lambda (cell)
       (let ((size (aref sizes cell-number)))
         (block-adjust-cell* cell block
                             cell-coordinate common-coordinate
                             size common-size)
         (incf cell-coordinate (+ size spacing))
         (incf cell-number)))
     block)))


;;; Row formatting
(defclass row-output-record (block-output-record)
  ()
  (:documentation "The protocol class representing row output records."))

(defun row-output-record-p (object)
  (typep object 'row-output-record))

(defgeneric map-over-row-cells (function row-record)
  (:documentation "Applies FUNCTION to all the cells in the row
ROW-RECORD, skipping intervening non-table output record structures.
FUNCTION is a function of one argument, an output record corresponding
to a table cell within the row."))

;;; Methods
(defmethod map-over-block-cells (function (block row-output-record))
  (map-over-row-cells function block))

(defmethod cell-common-size (cell (block row-output-record))
  (declare (type cell-output-record cell))
  (max (bounding-rectangle-height cell)
       (cell-min-height cell)))

(defmethod cell-size (cell (block row-output-record))
  (declare (type cell-output-record cell))
  (max (bounding-rectangle-width cell)
       (cell-min-width cell)))

(defmethod block-adjust-cell* (cell (block row-output-record)
                               cell-coordinate common-coordinate
                               size common-size)
  (declare (type cell-output-record cell)
           (type real cell-coordinate common-coordinate
                            size common-size))
  (adjust-cell* cell
                cell-coordinate common-coordinate
                size common-size))

;;; STANDARD-ROW-OUTPUT-RECORD class
(defclass standard-row-output-record (row-output-record
                                      standard-sequence-output-record)
  ())

(defmethod map-over-row-cells (function
                               (row-record standard-row-output-record))
  (map-over-output-records
   (lambda (record)
     (when (cell-output-record-p record) (funcall function record)))
   row-record))

(defmacro formatting-row ((&optional (stream t)
                           &key (record-type ''standard-row-output-record))
                           &body body)
  (declare (type symbol stream))
  (when (eq stream 't)
    (setq stream '*standard-output*))
  (with-gensyms (parent)
    `(progn
       (let ((,parent (stream-current-output-record ,stream)))
         (assert (table-output-record-p ,parent)))
       (with-new-output-record (,stream ,record-type)
         ,@body))))


;;; Column formatting
(defclass column-output-record (block-output-record)
  ()
  (:documentation "The protocol class representing column output records."))

(defun column-output-record-p (object)
  (typep object 'column-output-record))

(defgeneric map-over-column-cells (function column-record)
  (:documentation "Applies FUNCTION to all the cells in the column
COLUMN-RECORD, skipping intervening non-table output record
structures. FUNCTION is a function of one argument, an output record
corresponding to a table cell within the column."))

;;; Methods
(defmethod map-over-block-cells (function (block column-output-record))
  (map-over-column-cells function block))

(defmethod cell-common-size (cell (block column-output-record))
  (declare (type cell-output-record cell))
  (max (bounding-rectangle-width cell)
       (cell-min-width cell)))

(defmethod cell-size (cell (block column-output-record))
  (declare (type cell-output-record cell))
  (max (bounding-rectangle-height cell)
       (cell-min-height cell)))

(defmethod block-adjust-cell* (cell (block column-output-record)
                               cell-coordinate common-coordinate
                               size common-size)
  (declare (type cell-output-record cell)
           (type real cell-coordinate common-coordinate
                            size common-size))
  (adjust-cell* cell
                common-coordinate cell-coordinate
                common-size size))

;;; STANDARD-COLUMN-OUTPUT-RECORD class
(defclass standard-column-output-record (column-output-record
                                         standard-sequence-output-record)
  ())

(defmethod map-over-column-cells
    (function (column-record standard-column-output-record))
  (map-over-output-records
   (lambda (record)
     (when (cell-output-record-p record) (funcall function record)))
   column-record))

(defmacro formatting-column ((&optional (stream t)
                              &key (record-type ''standard-column-output-record))
                             &body body)
  (declare (type symbol stream))
  (when (eq stream 't)
    (setq stream '*standard-output*))
  (with-gensyms (parent)
    `(progn
       (let ((,parent (stream-current-output-record ,stream)))
         (assert (table-output-record-p ,parent)))
       (with-new-output-record (,stream ,record-type)
         ,@body))))

;;; Table formatting

(defclass table-output-record (output-record)
  ()
  (:documentation "The protocol class representing tabular output
records."))

(defun table-output-record-p (object)
  (typep object 'table-output-record))

(defgeneric map-over-table-elements (function table-record type)
  (:documentation "Applies FUNCTION to all the rows or columns of
TABLE-RECORD that are of type TYPE. TYPE is one of :ROW, :COLUMN or
:ROW-OR-COLUMN. FUNCTION is a function of one argument. The function
skips intervening non-table output record structures."))
(defgeneric adjust-table-cells (table-record stream))
(defgeneric adjust-multiple-columns (table-record stream))

;;; STANDARD-TABLE-OUTPUT-RECORD class
(defclass standard-table-output-record (table-output-record
                                        standard-sequence-output-record)
  ((x-spacing :initarg :x-spacing)
   (y-spacing :initarg :y-spacing)
   (multiple-columns :initarg :multiple-columns)
   (multiple-columns-x-spacing :initarg :multiple-columns-x-spacing)
   (equalize-column-widths :initarg :equalize-column-widths)))

(defmethod initialize-instance :after ((table standard-table-output-record)
                                       &rest initargs)
  (declare (ignore initargs))
  (unless (slot-boundp table 'multiple-columns-x-spacing)
    (setf (slot-value table 'multiple-columns-x-spacing)
          (slot-value table 'x-spacing))))

(defmacro formatting-table
    ((&optional (stream t)
      &rest args
      &key x-spacing y-spacing
      multiple-columns
      multiple-columns-x-spacing
      equalize-column-widths (move-cursor t)
      (record-type ''empty-standard-table-output-record)
      &allow-other-keys)
     &body body)
  (declare (ignore x-spacing y-spacing multiple-columns
                   multiple-columns-x-spacing
                   equalize-column-widths move-cursor record-type))
  (when (eq stream t)
    (setq stream '*standard-output*))
  (with-gensyms (cont)
    `(flet ((,cont (,stream) ,@body))
       (declare (dynamic-extent #',cont))
       (invoke-formatting-table ,stream #',cont
                                ,@args))))

(defun invoke-formatting-table
    (stream continuation
     &key x-spacing y-spacing
     multiple-columns
     multiple-columns-x-spacing
     equalize-column-widths
     (move-cursor t)
     (record-type 'empty-standard-table-output-record)
     &allow-other-keys)
  (setq x-spacing (parse-space stream (or x-spacing #\Space) :horizontal))
  (setq y-spacing (parse-space stream (or y-spacing
                                          (stream-vertical-spacing stream))
                               :vertical))
  (setq multiple-columns-x-spacing
        (if multiple-columns-x-spacing
            (parse-space stream multiple-columns-x-spacing :horizontal)
            x-spacing))
  (with-new-output-record
      (stream record-type table
              :x-spacing x-spacing
              :y-spacing y-spacing
              :multiple-columns multiple-columns
              :multiple-columns-x-spacing multiple-columns-x-spacing
              :equalize-column-widths equalize-column-widths)
    (multiple-value-bind (cursor-old-x cursor-old-y)
        (stream-cursor-position stream)
      (with-output-recording-options (stream :record t :draw nil)
        (funcall continuation stream)
        (finish-output stream))
      (adjust-table-cells table stream)
      (when multiple-columns (adjust-multiple-columns table stream))
      (setf (output-record-position table)
            (values cursor-old-x cursor-old-y))
      (if move-cursor
          ;; FIXME!!!
          #+ignore
          (setf (stream-cursor-position stream)
                (values cursor-new-x cursor-new-y))
          #-ignore
          nil
          (setf (stream-cursor-position stream)
                (values cursor-old-x cursor-old-y)))
      (replay table stream))))

;;; Internal
(defgeneric table-cell-spacing (table)
  (:documentation "Spacing between cells in blocks when the TABLE is
to be displayed on the STREAM."))

(defgeneric table-block-spacing (table)
  (:documentation "Spacing between blocks in the TABLE when it is to
be displayed on the STREAM."))

(defgeneric table-equalize-column-widths (table block-infos sizes)
  (:documentation "Equalizes widths of columns for TABLE destructively
modifying list BLOCK-INFOS or vector SIZES."))

(defmethod map-over-table-elements (function
                                    (table-record standard-table-output-record)
                                    type)
  (map-over-output-records
   (lambda (record)
     (when (or
            (and (row-output-record-p record)
                 (member type '(:row :row-or-column)))
            (and (column-output-record-p record)
                 (member type '(:column :row-or-column))))
       (funcall function record)))
   table-record))

(defun collect-block-infos (table)
  "Returns a list of BLOCK-INFOs for blocks in TABLE."
  (let ((infos nil))
    (map-over-table-elements
     (lambda (block) (push (block-info block) infos))
     table
     :row-or-column)
    (nreverse infos)))

(defmethod adjust-table-cells ((table-record standard-table-output-record)
                               stream)
  (declare (ignore stream))
  (let* ((cell-spacing (table-cell-spacing table-record))
         (block-spacing (table-block-spacing table-record))
         (infos (collect-block-infos table-record))
         (max-block-length (loop :for info :in infos
                              :maximize (block-info-number-of-cells info)))
         (sizes (make-array (list max-block-length)
                            :element-type 'real
                            :initial-element 0)))
    (loop :for info :in infos
       :for block-sizes = (block-info-cell-sizes info)
       :do (loop :for i = 0 :then (1+ i)
              :for s :in block-sizes
              :do (setf (aref sizes i)
                        (max (aref sizes i) s))))
    (when (slot-value table-record 'equalize-column-widths)
      (table-equalize-column-widths table-record infos sizes))
    (map-over-table-elements
     (let ((common-coordinate 0))
       (lambda (block)
         (let ((common-size (block-info-common-size (pop infos))))
           (adjust-block block sizes
                         cell-spacing common-coordinate common-size)
           (incf common-coordinate (+ common-size block-spacing)))))
     table-record
     :row-or-column)))

;;; Empty table
(defclass empty-standard-table-output-record (standard-table-output-record)
  ())

(defmethod add-output-record :after
    (child (record empty-standard-table-output-record))
  (change-class record
                (typecase child
                  (row-output-record 'table-of-rows-output-record)
                  (column-output-record 'table-of-columns-output-record))))

(defmethod adjust-table-cells
    ((table-record empty-standard-table-output-record) stream)
  (declare (ignore stream))
  ()) ; Nothing to do

(defmethod adjust-multiple-columns ((table empty-standard-table-output-record)
                                    stream)
  (declare (ignore stream))
  ()) ; Nothing to do

;;; Table of rows
(defclass table-of-rows-output-record (standard-table-output-record)
  ())

(defmethod add-output-record :after
    (child (record table-of-rows-output-record))
  (declare (ignore child))
  (when (column-output-record-p record)
    (error "Trying to add a column into a row table.")))

(defmethod table-cell-spacing ((table table-of-rows-output-record))
  (slot-value table 'x-spacing))
(defmethod table-block-spacing ((table table-of-rows-output-record))
  (slot-value table 'y-spacing))

(defmethod table-equalize-column-widths ((table table-of-rows-output-record)
                                         block-infos widths)
  (declare (ignore block-infos)
           (type (vector real) widths))
  (let ((max-width
         (loop :for w :across widths
            :maximize w)))
    (dotimes (i (length widths))
      (setf (aref widths i) max-width))))

(defmethod adjust-multiple-columns ((table table-of-rows-output-record) stream)
  (let ((n-columns (slot-value table 'multiple-columns))
        (x-spacing (slot-value table 'multiple-columns-x-spacing))
        (width (bounding-rectangle-width table))
        (stream-width (stream-text-margin stream)) ; XXX - (bounding-rectangle-min-x table)
        (n-rows 0))
    (when (eq n-columns t)
      (setq n-columns (floor (+ stream-width x-spacing)
                             (+ width x-spacing))))
    (when (<= n-columns 1) (return-from adjust-multiple-columns))
    (map-over-table-elements (lambda (row) (declare (ignore row))
                                     (incf n-rows))
                             table
                             :row)
    (when (<= n-rows 1) (return-from adjust-multiple-columns))
    (let* ((cy (bounding-rectangle-min-y table))
           (column-size (ceiling n-rows n-columns))
           (rest column-size)
           (dx 0)
           (dy 0))
      (map-over-table-elements
       (lambda (row)
         (multiple-value-bind (x y) (output-record-position row)
           (when (= rest 0)
             (incf dx (+ width x-spacing)) ; XXX
             (setq dy (- cy y))
             (setq rest column-size))
           (setf (output-record-position row) (values (+ x dx) (+ y dy)))
           (decf rest)))
       table :row))))

;;; Table of columns
(defclass table-of-columns-output-record (standard-table-output-record)
  ())

(defmethod add-output-record :after
    (child (record table-of-columns-output-record))
  (declare (ignore child))
  (when (row-output-record-p record)
    (error "Trying to add a column into a row table.")))

(defmethod table-cell-spacing ((table table-of-columns-output-record))
  (slot-value table 'y-spacing))
(defmethod table-block-spacing ((table table-of-columns-output-record))
  (slot-value table 'x-spacing))

(defmethod table-equalize-column-widths ((table table-of-columns-output-record)
                                         block-infos heights)
  (declare (ignore heights)
           (type list block-infos))
  (let ((max-width
         (loop :for i :in block-infos
            :maximize (block-info-common-size i))))
    (loop :for i :in block-infos
       :do (setf (block-info-common-size i) max-width))))

(defmethod adjust-multiple-columns ((table table-of-columns-output-record)
                                    stream)
  (declare (ignore stream))
  ()) ; Nothing to do (?)


;;; Item list formatting

(define-protocol-class item-list-output-record ()
  ())

(defgeneric map-over-item-cells (function item-list-record)
  (:documentation "Applies FUNCTION to the cells in ITEM-LIST-RECORD,
skipping skip over intervening non-table output record
structure. FUNCTION is a function of one argument, an output record
corresponding to a cell in the item list; it has dynamic extent."))
(defgeneric adjust-item-list-cells (item-list-record stream))

(defclass standard-item-list-output-record (item-list-output-record
                                            standard-sequence-output-record)
  ((x-spacing :initarg :x-spacing)
   (y-spacing :initarg :y-spacing)
   (initial-spacing :initarg :initial-spacing)
   (row-wise :initarg :row-wise)
   (n-rows :initarg :n-rows)
   (n-columns :initarg :n-columns)
   (max-width :initarg :max-width)
   (max-height :initarg :max-height)))

(defmethod map-over-item-cells
    (function (item-list-record standard-item-list-output-record))
  (map-over-output-records
   (lambda (record)
     (when (cell-output-record-p record) (funcall function record)))
   item-list-record))

(defmethod adjust-item-list-cells
    ((item-list standard-item-list-output-record) stream)
  (let ((width 0) (height 0)
        (n-rows (slot-value item-list 'n-rows))
        (n-columns (slot-value item-list 'n-columns))
        x (y 0)
        dx dy
        (n-items 0)
        n-rows-left)
    (map-over-item-cells
     (lambda (item)
       (maxf width (bounding-rectangle-width item))
       (maxf height (bounding-rectangle-height item))
       (incf n-items))
     item-list)
    (when (and n-rows n-columns (> n-items (* n-rows n-columns)))
      (setq n-rows nil))
    (cond ((not (or n-rows n-columns))
           (setq n-rows n-items
                 n-columns 1))
          ((not n-rows)
           (setq n-rows (ceiling n-items n-columns)))
          ((not n-columns)
           (setq n-columns (ceiling n-items n-rows))))
    (setq x (if (slot-value item-list 'initial-spacing)
                (/ (slot-value item-list 'x-spacing) 2)
                0))
    (setq dx (+ width (slot-value item-list 'x-spacing)))
    (setq dy (+ height (slot-value item-list 'y-spacing)))
    (setq n-rows-left n-rows)
    (map-over-item-cells
     (lambda (item)
       (adjust-cell* item x y width height)
       (cond ((= 0 (decf n-rows-left))
              (setq x (+ x dx)
                    y 0
                    n-rows-left n-rows))
             (t (incf y dy))))
     item-list)))

(defun format-items (items
                     &key stream printer presentation-type
                     x-spacing y-spacing n-columns n-rows
                     max-width max-height cell-align-x cell-align-y
                     initial-spacing (row-wise t) (move-cursor t)
                     record-type)
  (orf stream *standard-output*)
  (setq x-spacing (parse-space stream (or x-spacing #\Space) :horizontal))
  (setq y-spacing (parse-space stream (or y-spacing
                                          (stream-vertical-spacing stream))
                               :vertical))
  (orf record-type 'standard-item-list-output-record)
  (let ((printer (if printer
                     (if presentation-type
                         (lambda (item stream)
                           (with-output-as-presentation (stream item presentation-type)
                             (funcall printer item stream)))
                         printer)
                     (if presentation-type
                         (lambda (item stream)
                           (present item presentation-type :stream stream))
                         #'prin1))))
    (with-new-output-record
        (stream record-type item-list
                :x-spacing x-spacing
                :y-spacing y-spacing
                :initial-spacing initial-spacing
                :row-wise row-wise
                :n-rows n-rows
                :n-columns n-columns
                :max-width max-width
                :max-height max-height)
      (multiple-value-bind (cursor-old-x cursor-old-y)
          (stream-cursor-position stream)
        (with-output-recording-options (stream :record t :draw nil)
          (mapc (lambda (item)
                  (formatting-cell (stream :align-x cell-align-x
                                           :align-y cell-align-y)
                    (funcall printer item stream)))
                items)
          (finish-output stream))
        (adjust-item-list-cells item-list stream)
        (setf (output-record-position item-list)
              (values cursor-old-x cursor-old-y))
        (if move-cursor
            ;; FIXME!!!
            #+ignore
            (setf (stream-cursor-position stream)
                  (values cursor-new-x cursor-new-y))
            #-ignore
            nil
            (setf (stream-cursor-position stream)
                  (values cursor-old-x cursor-old-y)))
        (replay item-list stream)))))

(defmacro formatting-item-list
    ((&optional stream
                &key x-spacing y-spacing n-columns n-rows
                stream-width stream-height
                max-width max-height
                initial-spacing (row-wise t) (move-cursor t)
                record-type &allow-other-keys)
     &body body)
  ())