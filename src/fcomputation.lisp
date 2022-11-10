(defpackage :sento.future
  (:use :cl :blackbird)
  (:nicknames :future)
  (:export #:future
           #:with-fut
           #:make-future
           #:futurep
           #:complete-p
           #:fcompleted
           #:fresult
           #:fmap))

(in-package :sento.future)

(defclass future ()
  ((promise :initform nil))
  (:documentation
   "The wrapped [blackbird](https://orthecreedence.github.io/blackbird/) `promise`, here called `future`.  
Not all features of blackbird's `promise` are supported.  
This `future` wrapper changes the terminology. A `future` is a delayed computation.
A `promise` is the fulfillment of the delayed computation.

The `future` is used as part of `act:ask` but is available as a general utility."))

(defmethod print-object ((obj future) stream)
  (print-unreadable-object (obj stream :type t)
    (with-slots (promise) obj
      (format stream "promise: ~a" promise))))

(defmacro with-fut (fun)
  "`with-fut` is a convenience macro that makes crteating futures very easy.
Here is an example:

`fun`: a function to be executed for the delays execution (future).
The future will be resolved by the return value of `fun`.

```elisp
  (is (= 3
         (-> (with-fut 0)
           (fmap (lambda (value)
                   (with-fut (+ value 1))))
           (fmap (lambda (value)
                   (with-fut (+ value 1))))
           (fmap (lambda (value)
                   (with-fut (+ value 1))))
           (fresult))))
```
"
  `(make-future (lambda (resolve-fun)
                  (funcall resolve-fun ,fun))))

(defun make-future (resolve-fun)
  "Creates a future. `resolve-fun` is the lambda that is executed when the future is created.
`resolve-fun` takes a parameter which is the `resolve-fun` funtion. `resolve-fun` function
takes the `promise` as parameter which is the computed value. Calling `resolve-fun` with the promise
will fulfill the `future`.  
Manually calling `resolve-fun` to fulfill the `future` is in contrast to just fulfill the `future` from a return value. The benefit of the `resolve-fun` is flexibility. In  a multi-threaded environment `resolve-fun` could spawn a thread, in which case `resolve-fun` would return immediately but no promise can be given at that time. The `resolve-fun` can be called from a thread and provide the promise.

Create a future with:

```elisp
(make-future (lambda (resolve-fun) 
               (let ((promise (delayed-computation)))
                 (bt:make-thread (lambda ()
                   (sleep 0.5)
                   (funcall resolve-fun promise))))))
```
"
  (let ((future (make-instance 'future)))
    (with-slots (promise) future
      (setf promise
            (create-promise (lambda (resolve-fn reject-fn)
                              (declare (ignore reject-fn))
                              (funcall resolve-fun resolve-fn)))))
    future))

(defun make-future-plain (p)
  (let ((future (make-instance 'future)))
    (with-slots (promise) future
      (setf promise p))
    future))

(defun futurep (object)
  "Checks if type of `object` if `future`."
  (typep object 'future))

(defun complete-p (future)
  "Is `future` completed? Returns either `t` or `nil`."
  (with-slots (promise) future
    (promise-finished-p promise)))

(defun fcompleted (future completed-fun)
  "Install an on-completion handler function on the given `future`.
If the `future` is already complete then the `completed-fun` function is called immediately.
`completed-fun` takes a parameter which represents the fulfilled promise (the value with which the `future` was fulfilled)."
  (with-slots (promise) future
    (attach promise completed-fun))
  nil)

(defun fresult (future)
  "Get the computation result. If not yet available `:not-ready` is returned."
  (with-slots (promise) future
    (let ((the-promise (blackbird-base::lookup-forwarded-promise promise)))
      (with-slots (values) the-promise
        (if (null values)
            :not-ready
            (car values))))))

(defun fmap (future map-fun)
  (with-slots (promise) future
    (let* ((the-promise (blackbird-base::lookup-forwarded-promise promise))
           (cb-return-promise (blackbird-base::make-promise :name nil))
           (cb-wrapped (lambda (&rest args)
                         (blackbird-base::with-error-handling
                             (errexit promise)
                             (lambda (e)
                               (blackbird-base::signal-error cb-return-promise e)
                               (return-from errexit))
                           (let ((cb-return (multiple-value-list (apply map-fun args))))
                             ;; (format t "cb-return: ~a~%" cb-return)
                             ;; the below is a special treatment to make this
                             ;; work with out 'future'
                             (let ((new-cb-return
                                     (cond
                                       ((typep (car cb-return) 'future)
                                        (list (slot-value (car cb-return) 'promise)))
                                       (t
                                        cb-return))))
                               (apply #'blackbird-base::finish
                                      (append
                                       (list cb-return-promise)
                                       new-cb-return))))))))
      (blackbird-base::attach-errback the-promise
                                      (lambda (e)
                                        (blackbird-base::signal-error
                                         cb-return-promise
                                         e)))
      (blackbird-base::do-add-callback
        the-promise
        (blackbird-base::wrap-callback cb-wrapped))
      (blackbird-base::run-promise the-promise)
      (make-future-plain cb-return-promise))))
