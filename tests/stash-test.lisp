(defpackage :sento.stash-test
  (:use :cl :fiveam :sento.stash)
  (:export #:run!
           #:all-tests
           #:nil))
(in-package :sento.stash-test)

(def-suite stash-tests
  :description "Tests for stash mixin"
  :in sento.tests:test-suite)

(in-suite stash-tests)

(def-fixture test-context ()
  (let ((system (asys:make-actor-system '(:dispatchers (:shared (:workers 1))))))
    (unwind-protect
         (&body)
      (ac:shutdown system :wait t))))

(defclass stash-actor (act:actor stashing) ())

(test create-actor-with-stash
  (with-fixture test-context ()
    (is (not (null (ac:actor-of system
                                :type 'stash-actor
                                :receive (lambda (self msg state)
                                           (declare (ignore self msg state)))))))))

(test stash-actor-can-stash-messages
  (with-fixture test-context ()
    (let ((cut (ac:actor-of system
                            :type 'stash-actor
                            :receive (lambda (self msg state)
                                       (declare (ignore state))
                                       (stash:stash self msg)
                                       (cons :no-reply state)))))
      (act:tell cut :to-be-stashed-msg)
      (is-true (utils:await-cond 0.5
                 (has-stashed-messages cut))))))

(test stash-actor-can-unstash-messages-with-preserving-sender
  (with-fixture test-context ()
    (let* ((do-stash-message t)
           (received-msg nil)
           (sender (ac:actor-of system
                                :receive
                                (lambda (self msg state)
                                  (setf received-msg msg)
                                  (cons nil state))))
           (cut (ac:actor-of system
                             :type 'stash-actor
                             :receive
                             (lambda (self msg state)
                               (if do-stash-message
                                   (progn 
                                     (stash:stash self msg)
                                     (cons :no-reply state))
                                   (case msg
                                     (:unstash
                                      (progn
                                        (stash:unstash-all self)
                                        (cons :unstashed state)))
                                     (:to-be-stashed-msg
                                      (progn
                                        (act:tell act-cell:*sender* :stashed-msg-reply)
                                        (cons :no-reply state)))))))))
      (act:tell cut :to-be-stashed-msg sender)
      (utils:await-cond 0.5 (has-stashed-messages cut))
      (setf do-stash-message nil)
      (is (eq :unstashed (act:ask-s cut :unstash)))
      (is-true (utils:await-cond 0.5
                 (eq received-msg :stashed-msg-reply))))))

;; check on order of stash/unstash

(run! 'stash-tests)
