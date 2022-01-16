
(in-package :cl-gserver.actor-system)

(shadowing-import '(disp:make-dispatcher
                    disp:make-dispatcher-worker
                    ac:make-actor-context
                    ac:actor-of
                    ac:find-actors
                    ac:all-actors
                    ac:shutdown
                    ac:stop
                    ev:subscribe
                    ev:unsubscribe
                    ev:publish
                    wt:wheel-timer
                    wt:make-wheel-timer))

(defclass actor-system ()
  ((dispatchers :initform '()
                :reader dispatchers
                :documentation
                "Internal API: contains a list of available message dispatchers.")
   (config :initform '()
           :accessor config
           :documentation
           "Internal API: the actor-system configuration.")
   (internal-actor-context :initform nil
                           :reader internal-actor-context
                           :documentation
                           "Internal API: an actor context reserved for agents/actors used by the system.")
   (user-actor-context :initform nil
                       :reader user-actor-context
                       :documentation
                       "Internal API: an actor context for agents/actors created by the user.")
   (eventstream :initform nil
                :reader eventstream
                :documentation
                "The system event stream. See `ev:eventstream` for more info.")
   (timeout-timer :initform nil
                  :reader timeout-timer
                  :documentation
                  "A wheel-timer used for timeouts to make timeouts less resource expensive."))
  (:documentation
   "An `actor-system` is the opening facility. The first thing you do is to create an `actor-system` using the main constructor `make-actor-system`.
With the `actor-system` you can create actors via the `ac:actor-context` protocol function: `ac:actor-of`.

Or even simpler via `act:actor-of` which is a convenience macro:

```elisp
(act:actor-of (*system*)
                (lambda (self msg state)
                  ;; do stuff
                  (cons \"done\" state)))
```
"))

(defmethod print-object ((obj actor-system) stream)
  (print-unreadable-object (obj stream :type t)
    (with-slots (dispatchers config internal-actor-context user-actor-context) obj
      (format stream "config: ~a, user actors: ~a, internal actors: ~a"
              config
              (length (ac:all-actors user-actor-context))
              (length (ac:all-actors internal-actor-context))))))

(defmethod initialize-instance :after ((self actor-system) &key)
  (with-slots (user-actor-context internal-actor-context timeout-timer) self
    (setf user-actor-context (ac:make-actor-context self "/user"))
    (setf internal-actor-context (ac:make-actor-context self "/internal"))))

(defun make-actor-system (&optional config)
  "Creates an `actor-system`.
Allows to provide an optional configuration. See `asys:*default-config*`.
If no config is provided the default config is used.
Is a config provided then it is merged with the default config.
Config options in the existing config override the default config.
See `config:config-from`."
  (let ((system-config (config:merge-config config *default-config*))
        (system (make-instance 'actor-system)))
    (with-slots (dispatchers config internal-actor-context eventstream timeout-timer) system
      (setf config system-config)
      (setf eventstream (ev:make-eventstream internal-actor-context))

      (setf timeout-timer (wt:make-wheel-timer
                           (%get-timeout-timer-config config)))
      (setf dispatchers (make-dispatchers-from-config
                         (%get-dispatcher-config config)
                         internal-actor-context)))
    (lf:linfo system)
    system))

(defun %get-timeout-timer-config (system-config)
  (config:retrieve-section system-config :timeout-timer))

(defun %get-dispatcher-config (system-config)
  (config:retrieve-section system-config :dispatchers))

(defun make-dispatchers-from-config (config internal-actor-context)
  "Creates a plist of dispatchers for the `:dispatchers` configuration section."
  (loop :for dispatcher-key :in (config:retrieve-keys config)
        :for dispatcher-section = (config:retrieve-section config dispatcher-key)
        :append (list dispatcher-key
                      (apply #'disp:make-dispatcher
                             internal-actor-context
                             dispatcher-key
                             dispatcher-section))))

;; ----------------------------------------
;; Private Api
;; ----------------------------------------

(defun actor-context-for-key (context-key system)
  (case context-key
    (:internal (internal-actor-context system))
    (otherwise (user-actor-context system))))

(defun %actor-of (system create-fun dispatcher-id &key (context-key :user) (queue-size 0))
  "Private API to create system actors. Context-key is either `:internal` or `:user`
Users should use `actor-of`."
  (ac:actor-of (actor-context-for-key context-key system)
    create-fun
    :dispatcher-id dispatcher-id
    :queue-size queue-size))

(defun %find-actors (system path &key test key context-key)
  "Private API to find actors in both contexts the actor-system supports.
Users should use `ac:find-actors`."
  (let* ((root-path (format nil "/~a/" (string-downcase (symbol-name context-key))))
         (effective-path (if (str:starts-with-p "/" path)
                             (str:replace-first root-path "" path)
                             path)))
    (ac:find-actors
     (actor-context-for-key context-key system)
     effective-path
     :test test
     :key key)))

(defun %all-actors (system context-key)
  (ac:all-actors (actor-context-for-key context-key system)))

;; ----------------------------------------
;; Public Api / actor-context protocol
;; ----------------------------------------

(defmethod actor-of ((self actor-system) create-fun &key (dispatcher-id :shared) (queue-size 0))
  "See `ac:actor-of`"
  (%actor-of self create-fun dispatcher-id :context-key :user :queue-size queue-size))

(defmethod find-actors ((self actor-system) path &key (test #'string=) (key #'act-cell:name))
  "See `ac:find-actors`"
  (%find-actors self path :test test :key key :context-key :user))

(defmethod all-actors ((self actor-system))
  "See `ac:all-actors`"
  (%all-actors self :user))

(defmethod stop ((self actor-system) actor)
  "See `ac:stop`"
  (act-cell:stop actor))

(defmethod shutdown ((self actor-system))
  "See `ac:shutdown`"
  (wt:shutdown-wheel-timer (timeout-timer self))
  (ac:shutdown (user-actor-context self))
  (ac:shutdown (internal-actor-context self)))

;; ----------------------------------------
;; Public Api / eventcontext protocol
;; ----------------------------------------

(defmethod subscribe ((system actor-system) (subscriber act:actor) &optional pattern)
  "Convenience. Allows to subscribe to `ev:eventstream` by just providing the `asys:actor-system`."
  (ev:subscribe (eventstream system) subscriber pattern))

(defmethod unsubscribe ((system actor-system) (unsubscriber act:actor))
  "Convenience. Allows to unsubscribe to `ev:eventstream` by just providing the `asys:actor-system`."
  (ev:unsubscribe (eventstream system) unsubscriber))

(defmethod publish ((system actor-system) message)
  "Convenience. Allows to publish to `ev:eventstream` by just providing the `asys:actor-system`."
  (ev:publish (eventstream system) message))
