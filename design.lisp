;;; -*- Mode: Lisp; Package: CLIM-INTERNALS -*-

;;;  (c) copyright 1998,1999,2000 by Michael McDonald (mikemac@mikemac.com)
;;;  (c) copyright 2000 by Robert Strandh (strandh@labri.u-bordeaux.fr)
;;;  (c) copyright 2002 by Gilbert Baumann <unk6@rz.uni-karlsruhe.de>

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

;;;; Some Notes

;; The design design has a pitfall:
;;
;; As drawing is specified, a design of class opacity carries no color
;; and thus borrows its color from  +foreground-ink+. So that
;;
;; (make-opacity v) == (compose-in +foreground-ink+ (make-opacity v))
;;
;; This implies, that an opacity is not neccessary uniform, it depends
;; on the selected foreground ink.
;;
;; They halfway fix this by specifing that the mask argument of
;; compose-in and compose-out is thought as to be drawn with
;; +foreground-ink+ = +background-ink+ = +black+.
;;
;; But Is (make-opacity 1) really the same as +foreground-ink+? 
;;     Or: Is
;;         (compose-in D +foreground-ink+) different from
;;         (compose-in D (make-opacity 1))?
;;
;; If the above equation is true, we get a funny algebra:
;;
;; (make-opacity 0) = +transparent-ink+ = +nowhere+
;; (make-opacity 1) = +foreground-ink+ = +everywhere+
;;
;; --GB

;; It might be handy to have the equivalent of parent-relative
;; backgrounds. We can specify new indirect inks:
;;
;; +parent-background+
;; +parent-relative-background+
;; +parent-foreground+
;; +parent-relative-foreground+
;;
;; The relative one would have the same "absolute" origin as the
;; relevant inks of the parent.
;;
;; When they are evaluated, they look at the parent's
;; foreground/background ink. Though the relative variants are
;; expensive, when you want to scroll them ...
;;
;;
;; Further we really should specify some form of indirekt ink
;; protocol.
;;
;; --GB

;;;; Design Protocol

;;
;; DRAW-DESIGN already is all you need for a design protocol.
;;
;; --GB


(in-package :CLIM-INTERNALS)

(eval-when (:compile-toplevel :load-toplevel :execute)
(define-protocol-class design ())

;; Some internal superclasses:

(define-protocol-class uniform-design ())

;;; Color class

(define-protocol-class color (design uniform-design))

(defmethod print-object ((color color) stream)
  (print-unreadable-object (color stream :identity nil :type t)
    (multiple-value-call #'format stream "~,4F ~,4F ~,4F" (color-rgb color))))

;;; standard-color

(defclass standard-color (color)
  ((red   :initarg :red
          :initform 0
          :type (real 0 1))
   (green :initarg :green
          :initform 0
          :type (real 0 1))
   (blue  :initarg :blue
          :initform 0
          :type (real 0 1))))

(defmethod color-rgb ((color standard-color))
  (with-slots (red green blue) color
    (values red green blue)))

(defclass named-color (standard-color)
  ((name :initarg :name
	 :initform "Unnamed color") ))

(defmethod print-object ((color named-color) stream)
  (with-slots (name) color
    (print-unreadable-object (color stream :type t :identity nil)
      (format stream "~S" name))))

(defmethod make-load-form ((color named-color) &optional env)
  (declare (ignore env))
  (with-slots (name red green blue) color
    `(make-named-color ',name ,red ,green ,blue)))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *color-hash-table* (make-hash-table :test #'eql)))

(defun compute-color-key (red green blue)
  (+ (ash (round (* 255 red)) 16)
     (ash (round (* 255 green)) 8)
     (round (* 255 blue))))

(defun make-rgb-color (red green blue)
  (let ((key (compute-color-key red green blue)))
    (declare (type fixnum key))
    (or (gethash key *color-hash-table*)
	(setf (gethash key *color-hash-table*)
	      (make-instance 'named-color :red red :green green :blue blue)))))

(defun make-gray-color (intensity)
  (make-rgb-color intensity intensity intensity))

(defun make-named-color (name red green blue)
  (let* ((key (compute-color-key red green blue))
	 (entry (gethash key *color-hash-table*)))
    (declare (type fixnum key))
    (cond (entry
	   (when (string-equal (slot-value entry 'name) "Unnamed color")
	     (setf (slot-value entry 'name) name))
	   entry)
	  (t (setf (gethash key *color-hash-table*)
		   (make-instance 'named-color :name name :red red :green green :blue blue))))))
) ; eval-when

;;;    ;;; For ihs to rgb conversion, we use the formula 
;;;    ;;;  i = (r+g+b)/3
;;;    ;;;  s = 1-min(r,g,b)/i
;;;    ;;;  h =     60(g-b)/(max(r,g,b)-min(r,g,b)) if r >= g,b
;;;    ;;;      120+60(b-r)/(max(r,g,b)-min(r,g,b)) if g >= r,b
;;;    ;;;      240+60(r-g)/(max(r,g,b)-min(r,g,b)) if b >= r,g
;;;    ;;; First, we introduce colors x, y, z such that x >= y >= z
;;;    ;;; We compute x, y, and z and then determine the correspondance
;;;    ;;; between x, y, and z on the one hand and r, g, and b on the other. 
;;;    (defun make-ihs-color (i h s)
;;;      (assert (and (<= 0 i 1)
;;;                 (<= 0 s 1)
;;;                 (<= 0 h 360)))
;;;      (let ((ah (/ (abs (cond ((<= h 60) h)
;;;                            ((<= h 180) (- h 120))
;;;                            ((<= h 300) (- h 240))
;;;                            (t (- h 360))))
;;;                 60)))
;;;        (let* ((z (* i (- 1 s)))
;;;             (y (/ (+ (* ah (- (* 3 i) (* 2 z))) z) (+ 1 ah)))
;;;             (x (- (* 3 i) y z)))
;;;          (assert (and (<= 0 x 1)
;;;                     (<= 0 y 1)
;;;                     (<= 0 z 1)))
;;;          (cond ((<= h 60) (make-rgb-color x y z))
;;;              ((<= h 120) (make-rgb-color y x z))
;;;              ((<= h 180) (make-rgb-color z x y))
;;;              ((<= h 240) (make-rgb-color z y x))
;;;              ((<= h 300) (make-rgb-color y z x))
;;;              (t (make-rgb-color x z y))))))
;;;    
;;;    (defmethod color-ihs ((color color))
;;;      (multiple-value-bind (r g b) (color-rgb color)
;;;        (let ((max (max r g b))
;;;            (min (min r g b))
;;;            (intensity (/ (+ r g b) 3)))
;;;          (if (= max min)
;;;            (values intensity 0 0)
;;;            (let* ((saturation (- 1 (/ min intensity)))
;;;                   (diff (- max min))
;;;                   (hue (* 60 (cond ((= max r) (/ (- g b) diff))
;;;                                    ((= max g) (+ 2 (/ (- b r) diff)))
;;;                                    (t (+ 4 (/ (- r g) diff)))))))
;;;              (when (< hue 0)
;;;                (incf hue 360))
;;;	    (values intensity hue saturation))))))

;;;
;;; Below is a literal translation from Dylan's DUIM source code,
;;; which was itself probably literal translation from some Lisp code.
;;;

(defconstant +ihs-rgb-c1+ (sqrt (coerce 1/6 'double-float)))
(defconstant +ihs-rgb-c2+ (sqrt (coerce 1/2 'double-float)))
(defconstant +ihs-rgb-c3+ (sqrt (coerce 1/3 'double-float)))

(defun ihs-to-rgb (intensity hue saturation)
  (let* ((hh (- (* (mod (- hue 1/2) 1) 2 pi) pi))
         (c3 (cos saturation))
         (s3 (sin saturation))
         (cos-hh (cos hh))
         (sin-hh (sin hh))
         (x (* +ihs-rgb-c1+ s3 cos-hh intensity))
         (y (* +ihs-rgb-c2+ s3 sin-hh intensity))
         (z (* +ihs-rgb-c3+ c3 intensity)))
    (declare (type (real #.(- pi) #.pi) hh))
    (values (max 0 (min 1 (+ x x z)))
            (max 0 (min 1 (+ y z (- x))))
            (max 0 (min 1 (- z x y))))))

(defun rgb-to-ihs (red green blue)
  (let* ((x (* +ihs-rgb-c1+ (- (* 2 red) blue green)))
         (y (* +ihs-rgb-c2+ (- green blue)))
         (z (* +ihs-rgb-c3+ (+ red green blue)))
         (q (+ (* x x) (* y y)))
         (intensity (sqrt (+ q (* z z))))) ;sqrt(r^2 + g^2 + b^2)
    (if (zerop q)
        ;; A totally unsaturated color
        (values intensity 0 0)
      (let* ((hue (mod (/ (atan y x) (* 2 pi)) 1))
             (f1 (/ z intensity))
             (f2 (sqrt (- 1 (* f1 f1))))
             (saturation (atan f2 f1)))
        (values intensity hue saturation)))))

(defmethod color-ihs ((color color))
  (multiple-value-call #'rgb-to-ihs (color-rgb color)))

(defun make-ihs-color (i h s)
  (multiple-value-call #'make-rgb-color (ihs-to-rgb i h s)))


(defun make-contrasting-inks (n &optional k)
  (declare (special +contrasting-colors+))
  (if (> n (length +contrasting-colors+))
      (error "The argument N is out of range [1-~D]" (length +contrasting-colors+)))
  (if (null k)
      (subseq +contrasting-colors+ 0 n)
    (aref +contrasting-colors+ k)))

#||
;;; I used this function to generate the predefined colors and names - mikemac@mikemac.com

(defun generate-named-colors ()
  (with-open-file (out "X11-colors.lisp" :direction :output :if-exists :supersede)
    (with-open-file (in "/usr/X11/lib/X11/rgb.txt" :direction :input)
      (format out ";;; -*- Mode: Lisp; Package: CLIM-INTERNALS -*-~%~%")
      (format out "(in-package :CLIM-INTERNALS)~%~%")
      (loop with names = nil
	  for line = (read-line in nil nil)
	  until (null line)
	  do (if (eql (aref line 0) #\!)
		 (format out ";~A~%" (subseq line 1))
	       (multiple-value-bind (red index) (parse-integer line :start 0 :junk-allowed t)
		 (multiple-value-bind (green index) (parse-integer line :start index :junk-allowed t)
		   (multiple-value-bind (blue index) (parse-integer line :start index :junk-allowed t)
		     (let ((name (substitute #\- #\Space (string-trim '(#\Space #\Tab #\Newline) (subseq line index)))))
		       (format out "(defconstant +~A+ (make-named-color ~S ~,4F ~,4F ~,4F))~%" name name (/ red 255.0) (/ green 255.0) (/ blue 255.0))
		       (setq names (nconc names (list name))))))))
	  finally (format out "~%(defconstant +contrasting-colors+ (vector +black+ +red+ +green+ +blue+ +cyan+ +magenta+ +yellow+ +white+))~%~%")
		  (format out "(eval-when (eval compile load)~%  (export '(")
		  (loop for name in names
		      for count = 1 then (1+ count)
		      do (format out "+~A+ " name)
			 (when (= count 4)
			   (format out "~%            ")
			   (setq count 0)))
		  (format out "~%           )))~%")
	     ))))

||#

;;;;
;;;; 13.6 Indirect Inks
;;;;

(defclass indirect-ink (design) ())

(defvar +foreground-ink+ (make-instance 'indirect-ink))
(defvar +background-ink+ (make-instance 'indirect-ink))

(defmethod print-object ((ink (eql +foreground-ink+)) stream)
  (format stream "#.~S" '+foreground-ink+))

(defmethod print-object ((ink (eql +background-ink+)) stream)
  (format stream "#.~S" '+background-ink+))

;;;;
;;;; 13.4 Opacity
;;;;

(define-protocol-class opacity (design))

(defmethod print-object ((object opacity) stream)
  (print-unreadable-object (object stream :identity nil :type t)
    (format stream "~S" (opacity-value object))))

;; Note: Though tempting, opacity is not a uniform-design!

(defclass standard-opacity (opacity)
  ((value :initarg :value
          :type (real 0 1)
          :reader opacity-value)))

(defvar +transparent-ink+ 
    (make-instance 'standard-opacity :value 0))

(defun make-opacity (value)
  (setf value (clamp value 0 1))        ;defensive programming
  (cond ((= value 0)
         +transparent-ink+)
        ((= value 1)
         +foreground-ink+)
        (t
         (make-instance 'standard-opacity :value value))))

;;;;
;;;; 13.7 Flipping Ink
;;;;

(defclass standard-flipping-ink (design)
  ((design1 :initarg :design1
            :type design)
   (design2 :initarg :design2
            :type design)))

(defvar +flipping-ink+ (make-instance 'standard-flipping-ink 
                         :design1 +foreground-ink+
                         :design2 +background-ink+))

(defmethod print-object ((ink (eql +flipping-ink+)) stream)
  (format stream "#.~S" '+flipping-ink+))

(defmethod print-object ((flipper standard-flipping-ink) stream)
  (with-slots (design1 design2) flipper
    (print-unreadable-object (flipper stream :identity nil :type t)
      (format stream "~S ~S" design1 design2))))

(defmethod make-flipping-ink ((design1 design) (design2 design))
  (make-instance 'standard-flipping-ink :design1 design1 :design2 design2))

(defmethod make-flipping-ink ((design1 (eql +foreground-ink+)) 
                              (design2 (eql +background-ink+)))
  +flipping-ink+)

(defmethod make-flipping-ink ((design1 (eql +background-ink+)) 
                              (design2 (eql +foreground-ink+)))
  +flipping-ink+)

;;;;
;;;; 14 General Designs
;;;;

(declaim (inline color-blend-function))
(defun color-blend-function (r1 g1 b1 o1  r2 g2 b2 o2)
  (let* ((o3 (+ o1 (* (- 1 o1) o2)))
         (r3 (/ (+ (* r1 o1) (* (- 1 o1) o2 r2)) o3))
         (g3 (/ (+ (* g1 o1) (* (- 1 o1) o2 g2)) o3))
         (b3 (/ (+ (* b1 o1) (* (- 1 o1) o2 b2)) o3)))
    (values
     r3 g3 b3 o3)))

(defgeneric compose-over (design1 design2))
(defgeneric compose-in (ink mask))
(defgeneric compose-out (ink mask))

;; PATTERN is just the an abstract class of all pattern-like design. 

;; For performance might consider to sort out pattern, which consists
;; of uniform designs only and convert them to an RGBA-image.

(define-protocol-class pattern (design))

(defclass indexed-pattern (design)
  ((array   :initarg :array)
   (designs :initarg :designs)))
   
(defun make-pattern (array designs)
  (make-instance 'indexed-pattern :array array :designs designs))

(defmethod pattern-width ((pattern indexed-pattern))
  (with-slots (array) pattern
    (array-dimension array 1)))

(defmethod pattern-height ((pattern indexed-pattern))
  (with-slots (array) pattern
    (array-dimension array 0)))

(defclass stencil (pattern)
  ((array :initarg :array)))

(defun make-stencil (array)
  (make-instance 'stencil :array array))

(defmethod pattern-width ((pattern stencil))
  (with-slots (array) pattern
    (array-dimension array 1)))

(defmethod pattern-height ((pattern stencil))
  (with-slots (array) pattern
    (array-dimension array 0)))

;;;

(defclass rectangular-tile (design)
  ((width  :initarg :width      :reader rectangular-tile-width)
   (height :initarg :height     :reader rectangular-tile-height)
   (design :initarg :design     :reader rectangular-tile-design)))

(defun make-rectangular-tile (design width height)
  (make-instance 'rectangular-tile
    :width  width
    :height height
    :design design))

;;;

(defclass in-compositum (design)
  ((ink  :initarg :ink  :reader compositum-ink)
   (mask :initarg :mask :reader compositum-mask)))

(defmethod print-object ((object in-compositum) stream)
  (print-unreadable-object (object stream :identity nil :type t)
    (format stream "~S ~S ~S ~S"
            :ink (compositum-ink object)
            :mask (compositum-mask object))))

(defclass uniform-compositum (in-compositum)
  ;; we use this class to represent rgbo values
  ())

(defclass over-compositum (design)
  ((foreground :initarg :foreground :reader compositum-foreground)
   (background :initarg :background :reader compositum-background)))

(defmethod compose-in ((ink design) (mask design))
  (make-instance 'in-compositum
    :ink ink
    :mask mask))

(defmethod compose-over ((foreground design) (background design))
  (make-instance 'over-compositum
    :foreground foreground
    :background background))

;;;
;;; color
;;; opacity
;;; indirect-ink
;;; in-compositum
;;; over-compositum
;;; out-compositum
;;; uniform-compositum
;;;


;;;; ------------------------------------------------------------------------------------------
;;;;
;;;; COMPOSE-IN
;;;;

(defun make-uniform-compositum (ink opacity-value)
  (cond ((= opacity-value 0)
         +transparent-ink+)
        ((= opacity-value 1)
         ink)
        (t
         (make-instance 'uniform-compositum
           :ink ink
           :mask (make-opacity opacity-value)))))
;;; COLOR

(defmethod compose-in ((ink design) (mask color))
  (declare (ignorable ink))
  ink)

;;; OPACITY

(defmethod compose-in ((ink opacity) (mask opacity))
  (make-opacity (* (opacity-value ink) (opacity-value mask))))

(defmethod compose-in ((ink color) (mask opacity))
  (make-uniform-compositum ink (opacity-value mask)))

;;; UNIFORM-COMPOSITUM

(defmethod compose-in ((ink uniform-compositum) (mask uniform-compositum))
  (make-uniform-compositum (compositum-ink ink)
                           (* (opacity-value (compositum-mask ink))
                              (opacity-value (compositum-mask mask)))))

(defmethod compose-in ((ink uniform-compositum) (mask opacity))
  (make-uniform-compositum (compositum-ink ink)
                           (* (opacity-value (compositum-mask ink))
                              (opacity-value mask))))

(defmethod compose-in ((ink opacity) (mask uniform-compositum))
  (make-opacity (* (opacity-value mask)
                   (opacity-value (compositum-mask mask)))))

(defmethod compose-in ((ink color) (mask uniform-compositum))
  (make-uniform-compositum ink (opacity-value mask)))

;;; IN-COMPOSITUM

;; Since compose-in is associative, we can write it this way:
(defmethod compose-in ((ink in-compositum) (mask design))
  (compose-in (compositum-ink ink)
              (compose-in (compositum-mask ink)
                          mask)))

#+NYI
(defmethod compose-in ((ink opacity) (mask in-compositum))
  (declare (ignorable ink mask))
  )

#+NYI
(defmethod compose-in ((ink color) (mask in-compositum))
  (declare (ignorable ink mask))
  )


;;; OUT-COMPOSITUM

#+NYI
(defmethod compose-in ((ink out-compositum) (mask out-compositum))
  (declare (ignorable ink mask))
  )

#+NYI
(defmethod compose-in ((ink out-compositum) (mask in-compositum))
  (declare (ignorable ink mask))
  )

#+NYI
(defmethod compose-in ((ink out-compositum) (mask uniform-compositum))
  (declare (ignorable ink mask))
  )

#+NYI
(defmethod compose-in ((ink out-compositum) (mask opacity))
  (declare (ignorable ink mask))
  )

#+NYI
(defmethod compose-in ((ink uniform-compositum) (mask out-compositum))
  (declare (ignorable ink mask))
  )

#+NYI
(defmethod compose-in ((ink opacity) (mask out-compositum))
  (declare (ignorable ink mask))
  )

#+NYI
(defmethod compose-in ((ink color) (mask out-compositum))
  (declare (ignorable ink mask))
  )


;;; OVER-COMPOSITUM

#+NYI
(defmethod compose-in ((ink over-compositum) (mask over-compositum))
  (declare (ignorable ink mask))
  )

#+NYI
(defmethod compose-in ((ink over-compositum) (mask out-compositum))
  (declare (ignorable ink mask))
  )

#+NYI
(defmethod compose-in ((ink over-compositum) (mask in-compositum))
  (declare (ignorable ink mask))
  )

#+NYI
(defmethod compose-in ((ink over-compositum) (mask uniform-compositum))
  (declare (ignorable ink mask))
  )

#+NYI
(defmethod compose-in ((ink over-compositum) (mask opacity))
  (declare (ignorable ink mask))
  )

#+NYI
(defmethod compose-in ((ink out-compositum) (mask over-compositum))
  (declare (ignorable ink mask))
  )

#+NYI
(defmethod compose-in ((ink uniform-compositum) (mask over-compositum))
  (declare (ignorable ink mask))
  )

#+NYI
(defmethod compose-in ((ink opacity) (mask over-compositum))
  (declare (ignorable ink mask))
  )

#+NYI
(defmethod compose-in ((ink color) (mask over-compositum))
  (declare (ignorable ink mask))
  )

;;;; ------------------------------------------------------------------------------------------
;;;;
;;;;  Compose-Over
;;;;

;;; COLOR

(defmethod compose-over ((foreground color) (background design))
  (declare (ignorable background))
  foreground)

;;; OPACITY

(defmethod compose-over ((foreground opacity) (background opacity))
  (make-opacity
   (+ (opacity-value foreground)
      (* (- 1 (opacity-value foreground)) (opacity-value background)))))

(defmethod compose-over ((foreground opacity) (background color))
  (make-instance 'over-compositum
    :foreground foreground
    :background background))

;;; UNIFORM-COMPOSITUM

(defmethod compose-over ((foreground uniform-compositum) (background uniform-compositum))
  (multiple-value-bind (r g b o)
      (multiple-value-call #'color-blend-function
        (color-rgb (compositum-ink foreground))
        (opacity-value (compositum-mask foreground))
        (color-rgb (compositum-ink background))
        (opacity-value (compositum-mask background)))
    (make-uniform-compositum
     (make-rgb-color r g b)
     o)))

(defmethod compose-over ((foreground uniform-compositum) (background opacity))
  (make-instance 'over-compositum
    :foreground foreground
    :background background))

(defmethod compose-over ((foreground uniform-compositum) (background color))
  (multiple-value-bind (r g b o)
      (multiple-value-call #'color-blend-function
        (color-rgb (compositum-ink foreground))
        (opacity-value (compositum-mask foreground))
        (color-rgb background)
        1)
    (make-uniform-compositum
     (make-rgb-color r g b)
     o)))

(defmethod compose-over ((foreground opacity) (background uniform-compositum))
  (multiple-value-bind (r g b o)
      (multiple-value-call #'color-blend-function
        (color-rgb foreground)
        1
        (color-rgb (compositum-ink background))
        (opacity-value (compositum-mask background)))
    (make-uniform-compositum
     (make-rgb-color r g b)
     o)))

;;; IN-COMPOSITUM

#+NYI
(defmethod compose-over ((foreground in-compositum) (background in-compositum))
  (declare (ignorable foreground background))
  )

#+NYI
(defmethod compose-over ((foreground in-compositum) (background uniform-compositum))
  (declare (ignorable foreground background))
  )

#+NYI
(defmethod compose-over ((foreground in-compositum) (background opacity))
  (declare (ignorable foreground background))
  )

#+NYI
(defmethod compose-over ((foreground in-compositum) (background color))
  (declare (ignorable foreground background))
  )

#+NYI
(defmethod compose-over ((foreground uniform-compositum) (background in-compositum))
  (declare (ignorable foreground background))
  )

#+NYI
(defmethod compose-over ((foreground opacity) (background in-compositum))
  (declare (ignorable foreground background))
  )

;;; OUT-COMPOSITUM

#+NYI
(defmethod compose-over ((foreground out-compositum) (background out-compositum))
  (declare (ignorable foreground background))
  )

#+NYI
(defmethod compose-over ((foreground out-compositum) (background in-compositum))
  (declare (ignorable foreground background))
  )

#+NYI
(defmethod compose-over ((foreground out-compositum) (background uniform-compositum))
  (declare (ignorable foreground background))
  )

#+NYI
(defmethod compose-over ((foreground out-compositum) (background opacity))
  (declare (ignorable foreground background))
  )

#+NYI
(defmethod compose-over ((foreground out-compositum) (background color))
  (declare (ignorable foreground background))
  )

#+NYI
(defmethod compose-over ((foreground in-compositum) (background out-compositum))
  (declare (ignorable foreground background))
  )

#+NYI
(defmethod compose-over ((foreground uniform-compositum) (background out-compositum))
  (declare (ignorable foreground background))
  )

#+NYI
(defmethod compose-over ((foreground color) (background out-compositum))
  (declare (ignorable foreground background))
  )

;;; OVER-COMPOSITUM

#+NYI
(defmethod compose-over ((foreground over-compositum) (background over-compositum))
  (declare (ignorable foreground background))
  )

#+NYI
(defmethod compose-over ((foreground over-compositum) (background out-compositum))
  (declare (ignorable foreground background))
  )

#+NYI
(defmethod compose-over ((foreground over-compositum) (background in-compositum))
  (declare (ignorable foreground background))
  )

#+NYI
(defmethod compose-over ((foreground over-compositum) (background uniform-compositum))
  (declare (ignorable foreground background))
  )

#+NYI
(defmethod compose-over ((foreground over-compositum) (background opacity))
  (declare (ignorable foreground background))
  )

#+NYI
(defmethod compose-over ((foreground over-compositum) (background color))
  (declare (ignorable foreground background))
  )

#+NYI
(defmethod compose-over ((foreground out-compositum) (background over-compositum))
  (declare (ignorable foreground background))
  )

#+NYI
(defmethod compose-over ((foreground in-compositum) (background over-compositum))
  (declare (ignorable foreground background))
  )

#+NYI
(defmethod compose-over ((foreground uniform-compositum) (background over-compositum))
  (declare (ignorable foreground background))
  )

#+NYI
(defmethod compose-over ((foreground opacity) (background over-compositum))
  (declare (ignorable foreground background))
  )

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
