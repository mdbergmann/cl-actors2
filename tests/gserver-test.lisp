(defpackage :cl-gserver.gserver-test
  (:use :cl :trivia :fiveam
   :cl-gserver.gserver :cl-gserver.future :cl-gserver.system :cl-gserver.system-api)
  (:export #:run!
           #:all-tests
           #:nil
           #:assert-cond))

(in-package :cl-gserver.gserver-test)

(def-suite gserver-tests
  :description "gserver tests"
  :in cl-gserver.tests:test-suite)

(in-suite gserver-tests)

(log:config :warn)

(defun assert-cond (assert-fun max-time)
  (do ((wait-time 0.02 (+ wait-time 0.02))
       (fun-result nil (funcall assert-fun)))
      ((eq fun-result t) (return t))
    (if (> wait-time max-time) (return)
        (sleep 0.02))))

(def-fixture server-fixture (call-fun cast-fun state)
  (defclass test-server (gserver) ())
  (defmethod handle-call ((server test-server) message current-state)
    (funcall call-fun server message current-state))
  (defmethod handle-cast ((server test-server) message current-state)
    (funcall cast-fun server message current-state))

  (format t "Running no-system tests...~%")
  (let ((cut (make-instance 'test-server :state state)))
    (unwind-protect
         (&body)
      (call cut :stop)))
  (format t "Running no-system tests...done~%")
  (format t "Running system tests...~%")
  (let* ((system (make-system :num-workers 2))
         (cut (make-instance 'test-server
                             :state state)))
    (gs::attach-system cut system)
    (unwind-protect
         (&body)
      (call cut :stop)
      (shutdown system)))
  (format t "Running system tests...~%"))


(test get-server-name
  "Just retrieves the name of the server"

  (with-fixture server-fixture (nil nil nil)
    (print (name cut))
    (is (= 0 (search "gs-" (name cut))))))

(test create-simple-gserver
  "Creates a simple gserver"

  (let ((cut (make-gserver :name "Foo"
                           :state 0
                           :call-fun (lambda (self msg state)
                                       (declare (ignore self))
                                       (cons msg state))
                           :cast-fun (lambda (self msg state)
                                       (declare (ignore self))
                                       (cons msg state))
                           :after-init-fun (lambda (self state)
                                             (declare (ignore self state))
                                             (print "Foo")))))
    (is (string= "Bar" (call cut "Bar")))
    (call cut :stop)))

(test switch-message-box-when-attaching-system
  "Test if the message-box is switched when a system is attached."
  (let* ((system (make-system))
         (cut (make-gserver)))
    (unwind-protect
         (progn
           (is (typep (gs::msgbox cut) 'cl-gserver.messageb:message-box-bt))
           (gs::attach-system cut system)
           (is (typep (gs::msgbox cut) 'cl-gserver.messageb:message-box-dp)))
      (call cut :stop)
      (shutdown system))))

(test handle-call
  "Simple server handle-call test."

  (with-fixture server-fixture ((lambda (server message current-state)
                                  (declare (ignore server))
                                  (match message
                                    ((list :add n)
                                     (let ((new-state (+ current-state n)))
                                       (cons new-state new-state)))
                                    ((list :sub n)
                                     (let ((new-state (- current-state n)))
                                       (cons new-state new-state)))))
                                nil
                                0)
    (is (= 1000 (call cut '(:add 1000))))
    (is (= 500 (call cut '(:sub 500))))
    (is (eq :unhandled (call cut "Foo")))))

(test handle-async-call
  "Test handle a composable asynchronous call. on-completed after completion."

  (with-fixture server-fixture (nil
                                (lambda (server msg state)
                                  (declare (ignore server))
                                  (sleep 0.2)
                                  (match msg
                                    ((list :respondwith x)
                                     (cons x state))))
                                0)
    (let ((future (async-call cut '(:respondwith 1))))
      (is (eq :not-ready (get-result future)))
      (is (eq t (assert-cond (lambda () (complete-p future)) 1)))
      (is (= 1 (get-result future)))
  )))

(test handle-async-call-2
  "Test handle a composable asynchronous call. on-completed before completion."

  (with-fixture server-fixture (nil
                                (lambda (server msg state)
                                  (declare (ignore server))
                                  (sleep 0.5)
                                  (match msg
                                    ((list :respondwith x)
                                     (cons x state))))
                                0)
    (let ((future (async-call cut '(:respondwith 1)))
          (on-completed-result nil))
      (is (eq :not-ready (get-result future)))
      (on-completed future (lambda (result)
                                   (setf on-completed-result result)))
      (is (eq t (assert-cond (lambda () (complete-p future)) 1)))
      (is (= on-completed-result 1))
  )))

(test error-in-handler
  "testing error handling"
  
  (with-fixture server-fixture ((lambda (server message current-state)
                                  (declare (ignore server current-state))
                                  (log:info "Raising error condition...")
                                  (match message
                                    ((list :err) (error "Foo Error"))))
                                nil
                                nil)
  (let ((msg (call cut '(:err))))
    (format t "Got msg : ~a~%" msg)
    (is (not (null (cdr msg))))
    (is (eq (car msg) :handler-error))
    (is (string= "Foo Error" (format nil "~a" (cdr msg)))))))


(test stack-server
  "a gserver as stack."

  (with-fixture server-fixture ((lambda (server message current-state)
                                  (declare (ignore server))
                                  (format t "current-state: ~a~%" current-state)
                                  (match message
                                    (:pop
                                     (cons
                                      (car current-state)
                                      (cdr current-state)))
                                    (:get
                                     (cons current-state current-state))))
                                (lambda (server message current-state)
                                  (declare (ignore server))
                                  (format t "current-state: ~a~%" current-state)
                                  (match message
                                    ((cons :push value)
                                     (let ((new-state (append current-state (list value))))
                                       (cons new-state new-state)))))
                                '(5))
    (is (equalp '(5) (call cut :get)))
    (cast cut (cons :push 4))
    (sleep 0.01)
    (cast cut (cons :push 3))
    (sleep 0.01)
    (cast cut (cons :push 2))
    (sleep 0.01)
    (cast cut (cons :push 1))
    (sleep 0.3)
    (is (equalp '(5 4 3 2 1) (call cut :get)))
    (is (= 5 (call cut :pop)))
    (is (= 4 (call cut :pop)))
    (is (= 3 (call cut :pop)))
    (is (= 2 (call cut :pop)))
    (is (= 1 (call cut :pop)))
    (is (null (call cut :pop)))))

(test stopping-server
  "Stopping a server stops the message handling and frees resources."

  (defclass stopping-server (gserver) ())
  (defmethod handle-call ((server stopping-server) message current-state)
    (cons message current-state))

  (let ((cut (make-instance 'stopping-server)))
    (is (eq :stopped (call cut :stop)))))


(defun run-tests ()
  (run! 'get-server-name)
  (run! 'create-simple-gserver)
  (run! 'handle-call)
  (run! 'handle-async-call)
  (run! 'handle-async-call-2)
  (run! 'error-in-handler)
  (run! 'stack-server)
  (run! 'stopping-server))
