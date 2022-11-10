(defpackage :sento.future-test
  (:use :cl :fiveam :binding-arrows :sento.future)
  (:import-from #:utils
                #:assert-cond)
  (:export #:run!
           #:all-tests
           #:nil))
(in-package :sento.future-test)

(def-suite future-tests
  :description "Future tests"
  :in sento.tests:test-suite)

(in-suite future-tests)

(test create-future
  "Creates a future"

  (is (typep (make-future nil) 'future))
  (is (typep (make-future (lambda (resolve-fun)
                            (declare (ignore resolve-fun)) nil))
             'future))
  (is (futurep (make-future nil))))

(test provide-promise
  "Executes future and provides promise"

  (let ((future (make-future (lambda (resolve-fun)
                               (funcall resolve-fun "fulfilled")))))
    (is (eq t (complete-p future)))
    (is (string= "fulfilled" (fresult future)))))

(test on-complete-callback
  "Executes future and get result via on-complete callback."

  (let ((future (make-future (lambda (resolve-fun)
                               (funcall resolve-fun "fulfilled"))))
        (completed-value nil))
    (fcompleted future (lambda (value) (setf completed-value value)))
    (is (string= "fulfilled" completed-value))))

(test complete-with-delay
  "Test the completion with fcompleted callback with a delayed execution."

  (let ((future (make-future (lambda (resolve-fun)
                               (bt:make-thread
                                (lambda ()
                                  (sleep 0.5)
                                  (funcall resolve-fun "fulfilled"))))))
        (completed-value))
    (is (eq :not-ready (fresult future)))
    (fcompleted future (lambda (value) (setf completed-value value)))
    (is (eq t (assert-cond (lambda () (string= "fulfilled" completed-value)) 1)))))

(test mapping-futures--with-fut-macro
  "Tests mapping futures"
  (flet ((future-generator (x)
           (with-fut (+ x 1))))
    (let ((future (fmap (future-generator 0)
                        (lambda (completed-value)
                          (fmap (future-generator completed-value)
                                (lambda (completed-value)
                                  (fmap (future-generator completed-value)
                                        (lambda (completed-value)
                                          completed-value))))))))
      (is-true (assert-cond (lambda ()
                              (= 3 (fresult future)))
                            1)))))

(test mapping-using-arrows
  "Tests fmap using arrows aka threading"
  (is (= 3
         (-> (with-fut 0)
           (fmap (lambda (value)
                   (with-fut (+ value 1))))
           (fmap (lambda (value)
                   (with-fut (+ value 1))))
           (fmap (lambda (value)
                   (with-fut (+ value 1))))
           (fresult)))))

(test mapping--fut-errors
  "Tests fmap but one future errors"
  (is (= 3
         (-> (with-fut 0)
           (fmap (lambda (value)
                   (with-fut (+ value 1))))
           (fmap (lambda (value)
                   (with-fut (error "foo"))))
           (fmap (lambda (value)
                   (with-fut (+ value 1))))
           (fresult)))))

(test mapping-with-fcompleted
  (let ((completed-val))
    (-> (with-fut 0)
      (fmap (lambda (value)
              (with-fut (+ value 1))))
      (fcompleted (lambda (value)
                    (setf completed-val value))))
    (is-true (assert-cond (lambda ()
                            (= 1 completed-val))
                          1))))
