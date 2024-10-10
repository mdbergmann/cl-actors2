(defpackage :sento.timeutils
  (:nicknames :timeutils)
  (:use :cl)
  (:import-from #:alexandria
                #:with-gensyms)
  (:export #:wait-cond
           #:ask-timeout
           #:with-waitfor
           #:cause
           #:make-timer
           #:get-current-millis))

(in-package :sento.timeutils)

(defun wait-cond (cond-fun &optional (sleep-time 0.05) (max-time 12))
  "Waits until `cond-fun' is not `nil' or `max-time' elapsed.
This blocks the calling thread."
  (loop
    :for fun-result := (funcall cond-fun)
    :with wait-acc := 0
    :while (and (not fun-result) (< wait-acc max-time))
      :do (progn
            (sleep sleep-time)
            (incf wait-acc sleep-time))
    :finally (return fun-result)))

(define-condition ask-timeout (serious-condition)
  ((wait-time :initform nil
              :initarg :wait-time
              :reader wait-time)
   (cause :initform nil
          :initarg :cause
          :reader cause))
  (:report (lambda (c stream)
             (format stream "A timeout set to ~a seconds occurred. Cause: "
                     (wait-time c))
             (print (cause c) stream))))

(defmacro with-waitfor ((wait-time) &body body)
  "Spawns thread with timeout. Blocks until computation is done, or timeout elapsed."
  (with-gensyms (c)
    `(handler-case
         (bt2:with-timeout (,wait-time)
           ,@body)
       (bt2:timeout (,c)
         (error ,c))
       ;; the below is not needed anymore with SBCL 2.1. Will keep it anyway for compatibility.
       #+sbcl
       (sb-ext:timeout (,c)
         (declare (ignore ,c))
         (log:warn "sb-ext:timeout, wrapping to 'expired'.")
         (error 'bt2:timeout :seconds ,wait-time)))))

(defun make-timer (delay run-fun)
  (bt2:make-thread (lambda ()
                    (sleep delay)
                    (funcall run-fun))
                  :name (string (gensym "timer-"))))

(defun get-current-millis ()
  (let ((now (get-internal-real-time)))
    (if (> internal-time-units-per-second 1000)
        (truncate (/ now 1000))
        now)))
