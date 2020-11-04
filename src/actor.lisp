(defpackage :cl-gserver.actor
  (:use :cl)
  (:nicknames :act)
  (:import-from #:act-cell
                #:actor-cell
                #:pre-start
                #:after-stop
                #:handle-call
                #:handle-cast
                #:stop)
  (:import-from #:alexandria
                #:with-gensyms)
  (:import-from #:future
                #:make-future))

(in-package :cl-gserver.actor)

(defclass actor (actor-cell)
  ((receive-fun :initarg :receive-fun
                :initform (error "'receive-fun' must be specified!")
                :reader receive-fun)
   (context :initform nil
            :accessor context)
   (watchers :initform '()
             :reader watchers
             :documentation "List of watchers of this actor."))
  (:documentation
   "This is the `actor' class.
The `actor' does it's message handling in the `receive' function.
There is asynchronous `tell' (no response) and synchronous `ask' and asynchronous `async-ask' (with response).
To stop an actors message processing in order to cleanup resouces you should tell (either `tell' or `ask')
the `:stop' message. It will respond with `:stopped' (in case of `[async-]ask')."))

(defmethod make-actor (receive-fun &key name state)
  (make-instance 'actor
                 :name name
                 :state state
                 :receive-fun receive-fun))

;; -------------------------------
;; actor-cell impls
;; -------------------------------

(defmethod handle-call ((self actor) message state)
  (funcall (receive-fun self) self message state))
(defmethod handle-cast ((self actor) message state)
  (funcall (receive-fun self) self message state))

(defun stop-children (actor)
  (let ((context (context actor)))
    (when context
      (dolist (child (ac:all-actors context))
        (stop child)))))

(defun notify-watchers (actor)
  (dolist (watcher (watchers actor))
    (tell watcher (cons :stopped actor))))

(defmethod stop ((self actor))
  "If this actor has an `actor-context', also stop all children.
In any case stop the actor-cell."
  (stop-children self)
  (call-next-method)
  (notify-watchers self))

;; -------------------------------
;; actor protocol impl
;; -------------------------------

(defmethod tell ((self actor) message)
  (act-cell:cast self message))

(defmethod ask ((self actor) message &key (time-out nil))
  (act-cell:call self message :time-out time-out))

(defmethod watch ((self actor) watcher)
  (with-slots (watchers) self
    (setf watchers (cons watcher watchers))))

(defmethod unwatch ((self actor) watcher)
  (with-slots (watchers) self
    (setf watchers (utils:filter (lambda (w) (not (eq watcher w))) watchers))))

;; -------------------------------
;; Async handling
;; -------------------------------

(defclass async-waitor-actor (actor)
  ((pre-start-fun :initarg :pre-start-fun)))

(defmethod pre-start ((self async-waitor-actor) state)
  (when (next-method-p)
    (call-next-method))
  (with-slots (pre-start-fun) self
    (funcall pre-start-fun self state)))

(defmacro with-waitor-actor (actor message system time-out &rest body)
  (with-gensyms (self msg state msgbox waitor-actor delayed-cancel-msg)
    `(let ((,msgbox (if ,system
                        (make-instance 'mesgb:message-box/dp
                                       :dispatcher
                                       (getf (asys:dispatchers ,system) :shared))
                        (make-instance 'mesgb:message-box/bt)))
           (,waitor-actor (make-instance
                           'async-waitor-actor
                           :receive-fun (lambda (,self ,msg ,state)
                                          (unwind-protect
                                               (progn
                                                 (funcall ,@body ,msg)
                                                 (tell ,self :stop)
                                                 (cons ,msg ,state))
                                            (tell ,self :stop)))
                           :pre-start-fun (lambda (,self ,state)
                                            (declare (ignore ,state))
                                            ;; wrap the message into
                                            ;; delayed-cancellable-message
                                            (let ((,delayed-cancel-msg
                                                    (mesgb:make-delayed-cancellable-message
                                                     ,message ,time-out)))
                                              ;; this will call the `tell' function
                                              (act-cell::submit-message
                                               ,actor ,delayed-cancel-msg nil ,self ,time-out)))
                           :name (string (gensym "Async-ask-waiter-")))))
       (setf (act-cell:msgbox ,waitor-actor) ,msgbox))))

(defmethod async-ask ((self actor) message &key (time-out nil))
  (make-future (lambda (promise-fun)
                 (log:debug "Executing future function...")
                 (let* ((context (context self))
                        (system (if context (ac:system context) nil))
                        (timed-out nil)
                        (result-received nil))
                   (with-waitor-actor self message system time-out
                     (lambda (result)
                       (setf result-received t)
                       (log:info "Result: ~a, timed-out:~a" result timed-out)
                       (unless timed-out
                         (funcall promise-fun result))))
                   (when time-out
                     (handler-case
                         (utils:with-waitfor (time-out)
                           (utils:wait-cond (lambda () result-received) 0.1))
                       (bt:timeout (c)
                         (log:error "Timeout condition: ~a" c)
                         (setf timed-out t)
                         ;; fullfil the future
                         (funcall promise-fun
                                  (cons :handler-error
                                        (make-condition 'utils:ask-timeout :wait-time time-out
                                                                           :cause c))))))))))


;; (defmacro with-actor (&rest body)
;;   (format t "body: ~a~%" body)
;;   (labels ((filter-fun (x) (equal (car x) 'receive)))
;;     (let ((recv-form (cdr (car (fset:filter #'filter-fun body))))
;;           (rest-body (remove-if #'filter-fun body))
;;           (actor-sym (gensym))
;;           (msg-sym (gensym))
;;           (state-sym (gensym)))
;;       `(make-actor "tmp-actor"
;;                    :state nil
;;                    :receive-fun (lambda (,actor-sym ,msg-sym ,state-sym)
;;                                   ,(let ((self actor-sym)
;;                                          (msg msg-sym)
;;                                          (state state-sym))
;;                                      (car recv-form)))
;;                    :pre-start-fun (lambda (,actor-sym ,state-sym)
;;                                      ,(let ((self actor-sym)
;;                                             (state state-sym))
;;                                         (car rest-body)))))))
