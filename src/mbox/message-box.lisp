(defpackage :sento.messageb
  (:use :cl :sento.queue)
  (:import-from #:sento.miscutils
                #:mkstr
                #:assert-cond)
  (:import-from #:timeutils
                #:ask-timeout)
  (:import-from #:disp
                #:dispatch
                #:dispatch-async)
  (:nicknames :mesgb)
  (:export #:message-box/dp
           #:message-box/bt
           #:cancelled-p
           #:inner-msg
           #:submit
           #:stop))

(in-package :sento.messageb)

(defclass message-box-base ()
  ((name :initform (string (gensym "mesgb-"))
         :initarg :name
         :reader name
         :documentation "The name of the message-box.
The default name is concatenated of \"mesgb-\" and a `gensym` generated random number.")
   (processed-messages :initform 0)
   (queue :initform nil
          :documentation
          "Which type of queue will be used depends on the `max-queue-size` setting.")
   (max-queue-size :initform 0
                   :initarg :max-queue-size
                   :reader max-queue-size
                   :documentation
                   "0 or nil will make an unbounded queue. 
A value `> 0` will make a bounded queue.
Don't make it too small. A queue size of 1000 might be a good choice."))
  (:documentation "The user does not need to create a message-box manually. It is automatically created and added to the `actor` when the actor is created through `act:actor-of` or `ac:actor-of`."))

(defmethod initialize-instance :after ((self message-box-base) &key)
  (with-slots (queue max-queue-size) self
    (setf queue
          (case max-queue-size
            ((0 nil) (make-instance 'queue-unbounded))
            (t (make-instance 'queue-bounded :max-items max-queue-size))))))

(defmethod print-object ((obj message-box-base) stream)
  (print-unreadable-object (obj stream :type t)
    (with-slots (name processed-messages max-queue-size queue) obj
      (format stream "~a, processed messages: ~a, max-queue-size: ~a, queue: ~a"
              name
              processed-messages
              max-queue-size
              queue))))

(defgeneric submit (message-box-base message withreply-p time-out handler-fun-args)
  (:documentation "Submit a message to the mailbox to be queued and handled.
`handler-fun-args`: list with first element the function designator and rest arguments."))

(defgeneric stop (message-box-base &optional wait)
  (:documentation "Stops the message processing.
The message processing is not terminated while a message is still processed.
Rather it is a graceful stop by waiting until a message has been processed.
Provide `wait` EQ `T` to wait until the actor cell is stopped."))

(defmethod stop ((self message-box-base) &optional (wait nil))
  (declare (ignore wait))
  (with-slots (processed-messages) self
    (log:debug "~a: processed messages: ~a" (name self) processed-messages)))


;; ----------------------------------------
;; ------------- Generic ------------------
;; ----------------------------------------

(defun wait-and-probe-for-result (msgbox push-item)
  (with-slots (time-out handler-result cancelled-p) push-item
    (unless
        (assert-cond (lambda () (not (eq 'no-result handler-result))) time-out 0.1)
      (log:warn "~a: time-out elapsed but result not available yet!" (name msgbox))
      (setf cancelled-p t)
      (error 'ask-timeout :wait-time time-out))))

(defun call-handler-fun-args (handler-fun-args message)
  (when handler-fun-args
    (apply (car handler-fun-args) (cons message (cdr handler-fun-args)))))

;; ----------------------------------------
;; ------------- Bordeaux ----------------
;; ----------------------------------------

(defstruct message-item/bt
  (message nil)
  (withreply-p nil :type boolean)
  (withreply-lock nil)
  (withreply-cvar nil)
  (time-out nil)
  (cancelled-p nil :type boolean)
  (handler-fun-args nil :type list)
  (handler-result 'no-result))

(defclass message-box/bt (message-box-base)
  ((queue-thread :initform nil
                 :documentation
                 "The thread that pops queue items.")
   (should-run :initform t
               :documentation
               "Flag that indicates whether the message processing should commence."))
  (:documentation
   "Bordeaux-Threads based message-box with a single thread operating on a message queue.
This is used when the actor is created using a `:pinned` dispatcher type.
There is a limit on the maximum number of actors/agents that can be created with
this kind of queue because each message-box (and with that each actor) requires exactly one thread."))

(defmethod initialize-instance :after ((self message-box/bt) &key)
  (with-slots (name queue-thread) self
    (setf queue-thread (bt:make-thread
                        (lambda () (message-processing-loop self))
                        :name  (mkstr "message-thread-" name))))
  (when (next-method-p)
    (call-next-method)))

(defun message-processing-loop (msgbox)
  "The message processing loop."
  (loop
    :while (slot-value msgbox 'should-run)
    :do (pop-queue-and-process msgbox)))

(defun pop-queue-and-process (msgbox)
  "This blocks until a new queue item arrived."
  (log:trace "~a: trying to pop from queue..." (name msgbox))
  (with-slots (queue) msgbox
    (let ((item (queue:popq queue)))
      (log:debug "~a: got item: ~a" (name msgbox) item)
      (process-queue-item msgbox item)
      (incf (slot-value msgbox 'processed-messages)))))

(defun process-queue-item (msgbox item)
  "The `time-out' handling in here is to make sure that handling of the
message is 'interrupted' when the message was 'cancelled'.
This should happen in conjunction with the outer time-out in `submit/reply'."
  (with-slots (message handler-fun-args withreply-p withreply-lock withreply-cvar cancelled-p time-out) item
    (when cancelled-p
      (log:warn "~a: item got cancelled: ~a" (name msgbox) item)
      (when withreply-p
        (bt:condition-notify withreply-cvar))
      (return-from process-queue-item :cancelled))
    
    (when handler-fun-args
      (if withreply-p
          ;; protect this to make sure the lock is released.
          (bt:with-lock-held (withreply-lock)
            (unwind-protect
                 (if time-out
                     (unless cancelled-p
                       (call-handler-fun-args handler-fun-args message))
                     (call-handler-fun-args handler-fun-args message))
              (bt:condition-notify withreply-cvar)))
          (call-handler-fun-args handler-fun-args message)))))

(defmethod submit ((self message-box/bt) message withreply-p time-out handler-fun-args)
"Alternatively use `with-submit-handler` from your code to handle the message after it was 'popped' from the queue.
The `handler-fun-args` argument here will be `funcall`ed when the message was 'popped'."
  (log:trace "~a: submit message: ~a" (name self) message)
  (with-slots (queue) self
    (if withreply-p
        (submit/reply self queue message time-out handler-fun-args)
        (submit/no-reply self queue message handler-fun-args))))

(defun submit/no-reply (msgbox queue message handler-fun-args)
  "This is quite efficient, no locking necessary.
If the message was submitted with timeout then the timeout plays no role here, the message is handled anyhow.
The submitting code has to await the side-effect and possibly handle a timeout."
  (let ((push-item (make-message-item/bt
                    :message message
                    :handler-fun-args handler-fun-args)))
    (log:debug "~a: pushing item to queue: ~a" (name msgbox) push-item)
    (queue:pushq queue push-item)
    t))

(defun bt-handler-fun/reply (msg handler-fun-args msgbox-name message-item)
  (with-slots (handler-result) message-item
    (log:trace "~a: withreply: handler-fun-args..." msgbox-name)
    (setf handler-result
          (call-handler-fun-args handler-fun-args msg))
    (log:trace "~a: withreply: handler-fun-args result: ~a"
               msgbox-name handler-result)))

(defun submit/reply (msgbox queue message time-out handler-fun-args)
  "This requires some more action. This function has to provide a result and so it has to wait until
The queue thread has processed the message."
  (let* ((withreply-lock (bt:make-lock))
         (withreply-cvar (bt:make-condition-variable))
         (push-item (make-message-item/bt
                     :message message
                     :withreply-p t
                     :withreply-lock withreply-lock
                     :withreply-cvar withreply-cvar
                     :time-out time-out
                     :handler-result 'no-result)))
    (setf (message-item/bt-handler-fun-args push-item)
          (list #'bt-handler-fun/reply
                handler-fun-args
                (name msgbox)
                push-item))

    (log:trace "~a: withreply: waiting for arrival of result..." (name msgbox))
    (bt:with-lock-held (withreply-lock)
      (log:trace "~a: pushing item to queue: ~a" (name msgbox) push-item)
      (queue:pushq queue push-item)

      (if time-out
          (wait-and-probe-for-result msgbox push-item)
          (bt:condition-wait withreply-cvar withreply-lock)))
    
    (with-slots (handler-result) push-item
      (log:trace "~a: withreply: result should be available: ~a" (name msgbox) handler-result)
      handler-result)))

(defmethod stop ((self message-box/bt) &optional (wait nil))
  (when (next-method-p)
    (call-next-method))
  (with-slots (queue-thread should-run) self
    ;; the next just enforces a 'pop' on the queue to make the message processing stop
    (submit self :trigger-ending-the-processing-loop wait nil nil)
    (setf should-run nil)))


;; ----------------------------------------
;; ------------- dispatcher msgbox---------
;; ----------------------------------------

(defstruct message-item/dp
  (message nil)
  (time-out nil)
  (cancelled-p nil :type boolean)
  (handler-fun-args nil :type list)
  (handler-result 'no-result))

(defclass message-box/dp (message-box-base)
  ((dispatcher :initarg :dispatcher
               :initform (error "Dispatcher must be set!")
               :reader dispatcher
               :documentation
               "The dispatcher from the system.")
   (lock :initform (bt:make-lock)))
  (:documentation
   "This message box is a message-box that uses the `system`s `dispatcher`.
This has the advantage that an almost unlimited actors/agents can be created.
This message-box doesn't 'own' a thread. It uses the `dispatcher` to handle the message processing.
The `dispatcher` is kind of like a thread pool."))

(defmethod initialize-instance :after ((self message-box/dp) &key)
  (when (next-method-p)
    (call-next-method)))

(defun dispatcher-exec-fun (msgbox)
  "This function is effectively executed on a dispatcher actor.
It knows the message-box of the origin actor and acts on it.
It pops the ,essage from the message-boxes queue and calls the `handler-fun-args` on it.
The `handler-fun-args' is part of the message item."
  (with-slots (name queue) msgbox
    (log:trace "~a: popping message..." name)
    (let ((popped-item (popq queue)))
      (handle-popped-item popped-item msgbox))))

(defun handle-popped-item (popped-item msgbox)
  "Handles the popped message. Means: calls the `handler-fun-args` on the message."
  (with-slots (name lock) msgbox
    (with-slots (message cancelled-p handler-fun-args handler-result) popped-item
      (log:debug "~a: popped message: ~a" name popped-item)
      (when cancelled-p
        (log:warn "~a: item got cancelled: ~a" name popped-item))
      (unless cancelled-p
        ;; protect the actor from concurrent state changes on the shared dispatcher
        (bt:acquire-lock lock t)
        (unwind-protect
             (unless cancelled-p
               (setf handler-result (call-handler-fun-args handler-fun-args message))
               handler-result)
          (bt:release-lock lock))))))

(defmethod submit ((self message-box/dp) message withreply-p time-out handler-fun-args)
  "Submitting a message on a multi-threaded `dispatcher` is different as submitting on a single threaded message-box. On a single threaded message-box the order of message processing is guaranteed even when submitting from multiple threads. On the `dispatcher` this is not the case. The order cannot be guaranteed when messages are processed by different `dispatcher` threads. However, we still guarantee a 'single-threadedness' regarding the state of the actor. This is achieved here by protecting the `handler-fun-args` execution with a lock.

The `time-out` with the 'dispatcher mailbox' assumes that the message received the dispatcher queue
and the handler in a reasonable amount of time, so that the effective time-out applies on the actual
handling of the message on the dispatcher queue thread."
  (with-slots (name
               queue
               processed-messages
               dispatcher) self
    (incf processed-messages)
    (let ((push-item (make-message-item/dp
                      :message message
                      :handler-fun-args handler-fun-args
                      :time-out time-out))
          (dispatcher-fun (lambda () (funcall #'dispatcher-exec-fun self))))

      (log:info "~a: enqueuing... withreply-p: ~a, time-out: ~a, message: ~a"
                (name self) withreply-p time-out message)
      (pushq queue push-item)

      (if withreply-p
          (dispatch/reply self push-item dispatcher dispatcher-fun time-out)
          (dispatch/noreply self dispatcher dispatcher-fun)))))

(defun dispatch/reply (msgbox push-item dispatcher dispatcher-fun time-out)
  "Used by `ask-s'"
  (if time-out
      (dispatch/reply/timeout msgbox push-item dispatcher dispatcher-fun)
      (dispatch/reply/no-timeout msgbox dispatcher dispatcher-fun)))

(defun dispatch/reply/timeout (msgbox push-item dispatcher dispatcher-fun)
  (dispatch-async dispatcher dispatcher-fun)
  (wait-and-probe-for-result msgbox push-item)
  (slot-value push-item 'handler-result))

(defun dispatch/reply/no-timeout (msgbox dispatcher dispatcher-fun)
  (declare (ignore msgbox))
  (dispatch dispatcher dispatcher-fun))

(defun dispatch/noreply (msgbox dispatcher dispatcher-fun)
  "Used by `ask'."
  (declare (ignore msgbox))
  (dispatch-async dispatcher dispatcher-fun))

(defmethod stop ((self message-box/dp) &optional (wait nil))
  (declare (ignore wait))
  (when (next-method-p)
    (call-next-method)))
