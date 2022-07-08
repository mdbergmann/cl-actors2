(defpackage :cl-gserver.actor-system-test
  (:use :cl :fiveam :cl-mock :cl-gserver.actor-system)
  (:import-from #:act
                #:actor
                #:make-actor)
  (:import-from #:utils
                #:assert-cond)
  (:import-from #:disp
                #:workers
                #:shared-dispatcher)
  (:export #:run!
           #:all-tests
           #:nil))
(in-package :cl-gserver.actor-system-test)

(def-suite actor-system-tests
  :description "Tests for the actor system"
  :in cl-gserver.tests:test-suite)

(in-suite actor-system-tests)

(def-fixture test-system ()
  (let ((cut (make-actor-system)))
    (unwind-protect
         (&body)
      (ac:shutdown cut))))

(test create-system--default-config
  "Creates an actor-system by applying the default config."
  (let ((system (make-actor-system)))
    (unwind-protect
         (progn
           (is (not (null system)))
           (is (not (null (asys::internal-actor-context system))))
           (is (string= "/internal" (ac:id (asys::internal-actor-context system))))
           (is (typep (asys::internal-actor-context system) 'ac:actor-context))

           (is (not (null (asys::user-actor-context system))))
           (is (string= "/user" (ac:id (asys::user-actor-context system))))
           (is (typep (asys::user-actor-context system) 'ac:actor-context))
           (is (= 4 (length (disp:workers (getf (asys::dispatchers system) :shared)))))

           (is (not (null (asys:timeout-timer system))))
           (is (not (null (asys:evstream system)))))
      (ac:shutdown system))
      ))

(test create-system--custom-config
  "Create an actor-system by passing a custom config."
  (let ((system (make-actor-system '(:dispatchers (:shared (:workers 2))))))
    (is (= 2 (length (disp:workers (getf (asys::dispatchers system) :shared)))))
    (ac:shutdown system)))

(test create-system--additional-dispatcher
  "Creates an actor system with an additional custom dispatcher."
  (let ((system (make-actor-system '(:dispatchers (:foo (:workers 3))))))
    (is (= 4 (length (disp:workers (getf (asys::dispatchers system) :shared)))))
    (is (= 3 (length (disp:workers (getf (asys::dispatchers system) :foo)))))
    (ac:shutdown system)))

(test create-system--additional-dispatcher--manually
  "Creates an actor system with an additional custom dispatcher."
  (let ((system (make-actor-system)))
    (register-new-dispatcher system :foo-disp :workers 2 :strategy :round-robin)
    (is (= 4 (length (disp:workers (getf (asys::dispatchers system) :shared)))))
    (is (= 2 (length (disp:workers (getf (asys::dispatchers system) :foo-disp)))))
    (ac:shutdown system)))

(test create-system--check-defaults
  "Checking defaults on the system"
  (let ((system (make-actor-system)))
    (unwind-protect
         (progn
           (is (equal (asys::%get-dispatcher-config (asys::config system))
                      '(:shared (:workers 4 :strategy :random))))
           (is (equal (asys::%get-timeout-timer-config (asys::config system))
                      '(:resolution 500
                        :max-size 1000)))
           (is (equal (asys::%get-eventstream-config (asys::config system))
                      '(:dispatcher-id :shared)))
           (let ((dispatchers (dispatchers system)))
             (is-true (typep (getf dispatchers :shared) 'shared-dispatcher))
             (is (= 4 (length (workers (getf dispatchers :shared)))))))
      (ac:shutdown system))))

(test shutdown-system
  "Shutting down should stop all actors whether pinned or shared.
We use internal API here only for this test, do not use this otherwise."
  (let ((system (make-actor-system)))
    (asys::%actor-of system :receive (lambda ()) :dispatcher :pinned :context-key :user)
    (asys::%actor-of system :receive (lambda ()) :dispatcher :shared :context-key :user)
    (asys::%actor-of system :receive (lambda ()) :dispatcher :pinned :context-key :internal)
    (asys::%actor-of system :receive (lambda ()) :dispatcher :shared :context-key :internal)

    (ac:shutdown system)
    (is-true (assert-cond (lambda ()
                            (= 0 (length (ac:all-actors system)))) 2))))

(test shutdown-system--with-wait
  "Test shutting down the system by waiting for all actor to stop."
  (let* ((system (make-actor-system))
         (act1 (ac:actor-of system :receive (lambda (a b c)
                                              (declare (ignore a b c))
                                              (sleep 0.01)) :dispatcher :shared))
         (act2 (ac:actor-of system :receive (lambda (a b c)
                                              (declare (ignore a b c))
                                              (sleep 0.01)) :dispatcher :shared))
         (start-time (get-internal-real-time)))
    (act:tell act1 :foo)
    (act:tell act2 :foo)
    (ac:shutdown system :wait nil)
    (is (> (- (get-internal-real-time) start-time) 600))
    (is (= 0 (length (ac:all-actors system))))))

(test actor-of--verify-proper-root-path
  "Tests whether actors and contexts are created with proper paths."
  (with-fixture test-system ()
    (let ((actor (ac:actor-of cut :name "foo" :receive (lambda ()) :dispatcher :shared)))
      (is (string= "/user/foo" (act:path actor)))
      (is (string= "/user/foo" (ac:id (act:context actor)))))))

(test actor-of--shared--user
  "Creates actors in the system in user context with shared dispatcher."
  (with-fixture test-system ()
    (let ((actor (ac:actor-of cut :receive (lambda ()) :dispatcher :shared)))
      (is (not (null actor)))
      (is (typep (act-cell:msgbox actor) 'mesgb:message-box/dp))
      (is (not (null (act:context actor))))
      (is (eq (ac:system (act:context actor)) cut))
      (is (= 1 (length (ac:all-actors (asys::user-actor-context cut)))))
      (is (eq actor (first (ac:all-actors (asys::user-actor-context cut))))))))

(test actor-of--shared--internal
  "Creates actors in the system in internal context with shared dispatcher."
  (with-fixture test-system ()
    (let ((actor (asys::%actor-of cut :receive (lambda ()) :dispatcher :shared :context-key :internal)))
      (is (not (null actor)))
      (is (typep (act-cell:msgbox actor) 'mesgb:message-box/dp))
      (is (not (null (act:context actor))))
      (is (eq (ac:system (act:context actor)) cut))
      ;; 1 here, + 1 eventstream + 4 dispatch-workers
      (is (= 6 (length (ac:all-actors (asys::internal-actor-context cut)))))
      ;; first is eventstream actor
      (is (member actor (ac:all-actors (asys::internal-actor-context cut)) :test #'eq)))))

(test actor-of--pinned--user
  "Creates actors in the system in user context with pinned dispatcher."
  (with-fixture test-system ()
    (let ((actor (ac:actor-of cut :receive (lambda ()) :dispatcher :pinned)))
      (is (not (null actor)))
      (is (typep (act-cell:msgbox actor) 'mesgb:message-box/bt))
      (is (not (null (act:context actor))))
      (is (eq (ac:system (act:context actor)) cut))
      (is (= 1 (length (ac:all-actors (asys::user-actor-context cut)))))
      (is (eq actor (first (ac:all-actors (asys::user-actor-context cut))))))))

(test actor-of--pinned--internal
  "Creates actors in the system in internal context with pinned dispatcher."
  (with-fixture test-system ()
    (let ((actor (asys::%actor-of cut :receive (lambda ()) :dispatcher :pinned :context-key :internal)))
      (is (not (null actor)))
      (is (typep (act-cell:msgbox actor) 'mesgb:message-box/bt))
      (is (not (null (act:context actor))))
      (is (eq (ac:system (act:context actor)) cut))
      ;; 1 here, + 1 eventstream + 4 dispatch-workers
      (is (= 6 (length (ac:all-actors (asys::internal-actor-context cut)))))
      ;; first is eventstream actor
      (is (member actor (ac:all-actors (asys::internal-actor-context cut)) :test #'eq)))))

(test find-actors--in-system
  "Test finding actors in system."
  (with-fixture test-system ()
    (let ((act1 (ac:actor-of cut :name "foo" :receive (lambda ())))
          (act2 (ac:actor-of cut :name "foo2" :receive (lambda ())))
          (act3 (asys::%actor-of cut :name "foo3" :receive (lambda ()) :dispatcher :shared :context-key :internal))
          (act4 (asys::%actor-of cut :name "foo4" :receive (lambda ()) :dispatcher :shared :context-key :internal)))
      (is (eq act1 (first (ac:find-actors cut "foo"))))
      (is (eq act2 (first (ac:find-actors cut "foo2"))))
      (is (eq act3 (first (asys::%find-actors cut "foo3" :test #'string=
                                                         :key #'act-cell:name
                                                         :context-key :internal))))
      (is (eq act4 (first (asys::%find-actors cut "foo4" :test #'string=
                                                         :key #'act-cell:name
                                                         :context-key :internal))))
      (is (= 2 (length (ac:all-actors cut)))))))

(test find-actors--from-root
  "Test for finding actors"
  (with-fixture test-system ()
    (let* ((context cut)
           (act1 (ac:actor-of context :name "foo" :receive (lambda ()))))
      (ac:actor-of (act:context act1) :name "foo2" :receive (lambda ()))
      (ac:actor-of (act:context act1) :name "foo3" :receive (lambda ()))
      (is (= 1 (length (ac:find-actors context "/user/foo/foo2"))))
      (is (= 2 (length (ac:find-actors context "/user/foo/foo" :test #'str:starts-with-p)))))))

(test find-actors--no-root--using-user-context
  "Test for finding actors"
  (with-fixture test-system ()
    (let* ((context cut)
           (act1 (ac:actor-of context :name "foo" :receive (lambda ()))))
      (ac:actor-of (act:context act1) :name "foo2" :receive (lambda ()))
      (is (= 1 (length (ac:find-actors context "foo/foo2")))))))

(test all-actors--in-system-user-context
  "Retrieves all actors in user actor context of system."
  (with-fixture test-system ()
    (let ((act1 (ac:actor-of cut :name "foo" :receive (lambda ())))
          (act2 (ac:actor-of cut :name "foo2" :receive (lambda ()))))
      (is (= 2 (length (ac:all-actors cut))))
      (is (some (lambda (x) (eq act1 x)) (ac:all-actors cut)))
      (is (some (lambda (x) (eq act2 x)) (ac:all-actors cut))))))

(test stop-actor--in-system
  "Tests stopping an actor. This pretty much does the same as the method in actor-context."
  (with-fixture test-system ()
    (let ((act (ac:actor-of cut :name "foo" :receive (lambda ()))))
      (ac:stop cut act)
      (is (eq :stopped (act:ask-s act :foo))))))

(test creating-some-actors--and-collect-responses
  "Creating many actors should not pose a problem."
  (with-fixture test-system ()
    (let ((actors (loop :repeat 100
                        collect (ac:actor-of cut
                                  :receive (lambda (self msg state)
                                             (declare (ignore self))
                                             (cons (format nil "reply: ~a" msg) state)))))
          (ask-result nil))
      (time (setf ask-result
                  (every (lambda (x) (string= "reply: test" x))
                         (mapcar (lambda (actor)
                                   (act:ask-s actor "test"))
                                 actors))))
      (is-true ask-result))))

(test ev-subscribe-publish-receive--all-messages
  "Subscribe to eventstream, publish and receive. IntegTest."
  (with-fixture test-system ()
    (let* ((ev-received)
           (ev-listener (ac:actor-of cut
                          :receive (lambda (self msg state)
                                     (declare (ignore self state))
                                     (setf ev-received msg)
                                     (cons nil nil)))))
      (ev:subscribe (evstream cut) ev-listener)
      (ev:publish (evstream cut) "Foo")
      (is (assert-cond (lambda () (equal ev-received "Foo")) 1))
      (ev:unsubscribe (evstream cut) ev-listener))))
