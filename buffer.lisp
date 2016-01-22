;; -*- Mode: LISP; Package: LEM -*-

(in-package :lem)

(export '(*undo-limit*
          buffer
          buffer-p
          buffer-name
          buffer-filename
          buffer-modified-p
          buffer-read-only-p
          buffer-enable-undo-p
          buffer-major-mode
          buffer-minor-modes
          buffer-nlines
          buffer-truncate-lines
          buffer-enable-undo
          buffer-disable-undo
          buffer-put-attribute
          buffer-remove-attribute
          buffer-get-char
          buffer-line-length
          buffer-line-string
          buffer-end-line-p
          map-buffer-lines
          buffer-take-lines
          buffer-insert-char
          buffer-insert-newline
          buffer-insert-line
          buffer-delete-char
          buffer-erase
          buffer-directory
          buffer-undo-boundary
          get-bvar
          clear-buffer-variables))

(defstruct (line (:constructor %make-line))
  prev
  fatstr
  tags
  symbol-tov-list
  region
  next)

(defun make-line (prev next str)
  (let ((line (%make-line :next next
                          :prev prev
                          :fatstr (make-fatstring str 0))))
    (when next
      (setf (line-prev next) line))
    (when prev
      (setf (line-next prev) line))
    line))

(defun line-str (line)
  (fat-string (line-fatstr line)))

(defun line-length (line)
  (length (line-str line)))

(defun line-clear-attribute (line)
  (change-font (line-fatstr line) 0 :and))

(defun line-put-attribute (line start end attr)
  (change-font (line-fatstr line) attr :to start end)
  t)

(defun line-remove-attribute (line start end attr)
  (change-font (line-fatstr line) (lognot attr) :and start end)
  t)

(defun line-get-attribute (line pos)
  (aref (fat-font-data (line-fatstr line)) pos))

(defun line-contains-attribute (line pos attr)
  (/= 0 (logand attr (line-get-attribute line pos))))

(defun line-add-tag (line start end tag)
  (when tag
    (push (list start end tag) (line-tags line))
    t))

(defun line-clear-tags (line)
  (setf (line-tags line) nil)
  t)

(defun line-free (line)
  (when (line-prev line)
    (setf (line-next (line-prev line))
          (line-next line)))
  (when (line-next line)
    (setf (line-prev (line-next line))
          (line-prev line)))
  (setf (line-prev line) nil
        (line-next line) nil
        (line-fatstr line) nil))

(defun line-step-n (line n step-f)
  (do ((l line (funcall step-f l))
       (i 0 (1+ i)))
      ((= i n) l)))

(defun line-forward-n (line n)
  (line-step-n line n 'line-next))

(defun line-backward-n (line n)
  (line-step-n line n 'line-prev))

(define-class buffer () (window-buffer)
  name
  filename
  modified-p
  read-only-p
  enable-undo-p
  major-mode
  minor-modes
  head-line
  tail-line
  cache-line
  cache-linum
  mark-p
  mark-overlay
  mark-marker
  keep-binfo
  nlines
  undo-size
  undo-stack
  redo-stack
  undo-node
  saved-node
  overlays
  markers
  truncate-lines
  external-format
  variables)

(defvar *undo-modes* '(:edit :undo :redo))
(defvar *undo-mode* :edit)
(defvar *undo-limit* 100000)

(defun make-buffer (name &key filename read-only-p (enable-undo-p t))
  (let ((buffer (make-instance 'buffer
                               :name name
                               :filename filename
                               :read-only-p read-only-p
                               :enable-undo-p enable-undo-p
                               :major-mode 'fundamental-mode))
        (line (make-line nil nil "")))
    (setf (buffer-head-line buffer) line)
    (setf (buffer-tail-line buffer) line)
    (setf (buffer-cache-line buffer) line)
    (setf (buffer-cache-linum buffer) 1)
    (setf (buffer-mark-p buffer) nil)
    (setf (buffer-mark-overlay buffer) nil)
    (setf (buffer-mark-marker buffer) nil)
    (setf (buffer-nlines buffer) 1)
    (setf (buffer-undo-size buffer) 0)
    (setf (buffer-undo-stack buffer) nil)
    (setf (buffer-redo-stack buffer) nil)
    (setf (buffer-undo-node buffer) 0)
    (setf (buffer-saved-node buffer) 0)
    (setf (buffer-overlays buffer) nil)
    (setf (buffer-markers buffer) nil)
    (setf (buffer-truncate-lines buffer) t)
    (setf (buffer-variables buffer) (make-hash-table :test 'equal))
    (unless (ghost-buffer-p buffer)
      (push buffer *buffer-list*))
    buffer))

(defun buffer-p (x)
  (typep x 'buffer))

(defmethod print-object ((buffer buffer) stream)
  (format stream "#<BUFFER ~a ~a>"
          (buffer-name buffer)
          (buffer-filename buffer)))

(defun buffer-enable-undo (buffer)
  (setf (buffer-enable-undo-p buffer) t)
  nil)

(defun buffer-disable-undo (buffer)
  (setf (buffer-enable-undo-p buffer) nil)
  (setf (buffer-undo-size buffer) 0)
  (setf (buffer-undo-stack buffer) nil)
  (setf (buffer-redo-stack buffer) nil)
  (setf (buffer-undo-node buffer) 0)
  (setf (buffer-saved-node buffer) 0)
  nil)

(defun buffer-modify (buffer)
  (setf (buffer-modified-p buffer)
        (if (buffer-modified-p buffer)
            (1+ (mod (buffer-modified-p buffer)
                     #.(floor most-positive-fixnum 2)))
            0)))

(defun buffer-save-node (buffer)
  (setf (buffer-saved-node buffer)
        (buffer-undo-node buffer)))

(defun push-undo-stack (buffer elt)
  (cond ((<= (+ *undo-limit* (floor (* *undo-limit* 0.3)))
             (buffer-undo-size buffer))
         (setf (buffer-undo-stack buffer)
               (subseq (buffer-undo-stack buffer)
                       0
                       *undo-limit*))
         (setf (buffer-undo-size buffer)
               (1+ (length (buffer-undo-stack buffer)))))
        (t
         (incf (buffer-undo-size buffer))))
  (let ((interrupt-p))
    (when-interrupted-flag :undo
                           (setq interrupt-p t)
                           (push :separator
                                 (buffer-undo-stack buffer)))
    (push elt (buffer-undo-stack buffer))
    interrupt-p))

(defun push-redo-stack (buffer elt)
  (push elt (buffer-redo-stack buffer)))

(defmacro with-push-undo ((buffer) &body body)
  (let ((gmark-marker (gensym)))
    `(when (and (buffer-enable-undo-p ,buffer)
                (not (ghost-buffer-p ,buffer)))
       (let ((,gmark-marker (buffer-mark-marker ,buffer)))
         (let ((elt #'(lambda ()
                        (setf (buffer-mark-marker ,buffer) ,gmark-marker)
                        ,@body)))
           (ecase *undo-mode*
             (:edit
              (when (push-undo-stack ,buffer elt)
                (incf (buffer-undo-node ,buffer)))
              (setf (buffer-redo-stack ,buffer) nil))
             (:redo
              (push-undo-stack ,buffer elt))
             (:undo
              (push-redo-stack ,buffer elt))))))))

(defmacro buffer-read-only-guard (buffer)
  `(when (buffer-read-only-p ,buffer)
     (throw 'abort 'readonly)))

(defun buffer-line-set-attribute (line-set-fn buffer attr linum
                                  &optional start-column end-column)
  (let ((line (buffer-get-line buffer linum)))
    (funcall line-set-fn
             line
             (or start-column 0)
             (or end-column (fat-length (line-fatstr line)))
             attr)))

(defun buffer-set-attribute (line-set-fn buffer start end attr)
  (with-points (((start-linum start-column) start)
                ((end-linum end-column) end))
    (cond ((= start-linum end-linum)
           (buffer-line-set-attribute line-set-fn
                                      buffer
                                      attr
                                      start-linum
                                      start-column
                                      end-column))
          (t
           (buffer-line-set-attribute line-set-fn
                                      buffer
                                      attr
                                      start-linum
                                      start-column)
           (buffer-line-set-attribute line-set-fn
                                      buffer
                                      attr
                                      end-linum
                                      0
                                      end-column)
           (loop
             for linum from (1+ start-linum) below end-linum
             do (buffer-line-set-attribute line-set-fn
                                           buffer
                                           attr
                                           linum))))))

(defun buffer-put-attribute (buffer start end attr)
  (buffer-set-attribute #'line-put-attribute buffer start end attr))

(defun buffer-remove-attribute (buffer start end attr)
  (buffer-set-attribute #'line-remove-attribute buffer start end attr))

(defun buffer-add-overlay (buffer overlay)
  (push overlay (buffer-overlays buffer)))

(defun buffer-delete-overlay (buffer overlay)
  (setf (buffer-overlays buffer)
        (delete overlay (buffer-overlays buffer))))

(defun buffer-add-marker (buffer marker)
  (push marker (buffer-markers buffer)))

(defun buffer-delete-marker (buffer marker)
  (setf (buffer-markers buffer)
        (delete marker (buffer-markers buffer))))

(defun buffer-mark-cancel (buffer)
  (when (buffer-mark-p buffer)
    (setf (buffer-mark-p buffer) nil)
    (delete-overlay (buffer-mark-overlay buffer))))

(defun buffer-update-mark-overlay (buffer)
  (when (buffer-mark-p buffer)
    (let (start
          end
          (mark-point (marker-point (buffer-mark-marker buffer)))
          (cur-point (point)))
      (if (point< mark-point cur-point)
          (setq start mark-point
                end cur-point)
          (setq start cur-point
                end mark-point))
      (when (buffer-mark-overlay buffer)
        (delete-overlay (buffer-mark-overlay buffer)))
      (setf (buffer-mark-overlay buffer)
            (make-overlay start end :attr (make-attr :color :blue :reverse-p t))))))

(defun %buffer-get-line (buffer linum)
  (cond
   ((= linum (buffer-cache-linum buffer))
    (buffer-cache-line buffer))
   ((> linum (buffer-cache-linum buffer))
    (if (< (- linum (buffer-cache-linum buffer))
           (- (buffer-nlines buffer) linum))
        (line-forward-n
         (buffer-cache-line buffer)
         (- linum (buffer-cache-linum buffer)))
        (line-backward-n
         (buffer-tail-line buffer)
         (- (buffer-nlines buffer) linum))))
   (t
    (if (< (1- linum)
           (- (buffer-cache-linum buffer) linum))
        (line-forward-n
         (buffer-head-line buffer)
         (1- linum))
        (line-backward-n
         (buffer-cache-line buffer)
         (- (buffer-cache-linum buffer) linum))))))

(defun buffer-get-line (buffer linum)
  (cond ((< linum 1)
         (when *debug-p*
           (pdebug (format nil
                           "~&line number < 1: ~a ~a~%"
                           buffer
                           linum)
                   (merge-pathnames "LEM-WARNING"
                                    (truename "./")))
           (minibuf-print "FOUND BUG"))
         (setq linum 1))
        ((< #1=(buffer-nlines buffer) linum)
         (when *debug-p*
           (pdebug (format nil
                           "~&buffer nlines < line number: ~a ~a~%"
                           buffer
                           linum)
                   (merge-pathnames "LEM-WARNING"
                                    (truename "./")))
           (minibuf-print "FOUND BUG"))
         (setq linum #1#)))
  (let ((line (%buffer-get-line buffer linum)))
    (setf (buffer-cache-linum buffer) linum)
    (setf (buffer-cache-line buffer) line)
    line))

(defun buffer-get-char (buffer linum column)
  (let ((line (buffer-get-line buffer linum)))
    (when (line-p line)
      (let* ((str (line-fatstr line))
             (len (fat-length str)))
        (cond
         ((<= 0 column (1- len))
          (fat-char str column))
         ((= column len)
          #\newline))))))

(defun buffer-line-length (buffer linum)
  (fat-length (line-fatstr (buffer-get-line buffer linum))))

(defun buffer-line-fatstring (buffer linum)
  (let ((line (buffer-get-line buffer linum)))
    (when (line-p line)
      (line-fatstr line))))

(defun buffer-line-string (buffer linum)
  (let ((fatstr (buffer-line-fatstring buffer linum)))
    (when fatstr
      (fat-string fatstr))))

(defun buffer-end-line-p (buffer linum)
  (let ((line (buffer-get-line buffer linum)))
    (not (line-next line))))

(defun map-buffer (fn buffer &optional start-linum)
  (do ((line (if start-linum
                 (buffer-get-line buffer start-linum)
                 (buffer-head-line buffer))
             (line-next line))
       (linum (or start-linum 1) (1+ linum)))
      ((null line))
    (funcall fn line linum)))

(defun map-buffer-lines (fn buffer &optional start end)
  (let ((head-line
         (if start
             (buffer-get-line buffer start)
             (buffer-head-line buffer))))
    (unless end
      (setq end (buffer-nlines buffer)))
    (do ((line head-line (line-next line))
         (i (or start 1) (1+ i)))
        ((or (null line) (< end i)))
      (funcall fn
               (fat-string (line-fatstr line))
               (not (line-next line))
               i))))

(defun buffer-take-lines (buffer &optional linum len)
  (unless linum
    (setq linum 1))
  (unless len
    (setq len (buffer-nlines buffer)))
  (let ((strings))
    (map-buffer-lines
     #'(lambda (str eof-p linum)
         (declare (ignore eof-p linum))
         (push str strings))
     buffer
     linum
     (+ linum len -1))
    (nreverse strings)))

(defun set-attr-display-line (disp-lines
                              attr
                              start-linum
                              linum
                              start-column
                              end-column)
  (let ((i (- linum start-linum)))
    (when (<= 0 i (1- (length disp-lines)))
      (unless end-column
        (setq end-column (fat-length (aref disp-lines i))))
      (let ((fatstr (aref disp-lines i)))
        (change-font fatstr
                     attr
                     :to
                     start-column
                     (min end-column (fat-length fatstr)))))))

(defun set-attr-display-lines (disp-lines
                               attr
                               top-linum
                               start-linum
                               start-column
                               end-linum
                               end-column)
  (set-attr-display-line disp-lines
                         attr
                         top-linum
                         start-linum
                         start-column
                         nil)
  (loop :for linum :from (1+ start-linum) :below end-linum :do
    (set-attr-display-line disp-lines
                           attr
                           top-linum
                           linum
                           0
                           nil))
  (set-attr-display-line disp-lines
                         attr
                         top-linum
                         end-linum
                         0
                         end-column))

(defun display-lines-set-overlays (disp-lines overlays start-linum end-linum)
  (loop
    for overlay in overlays
    for start = (overlay-start overlay)
    for end = (overlay-end overlay)
    do (cond ((and (= (point-linum start) (point-linum end))
                   (<= start-linum (point-linum start) (1- end-linum)))
              (set-attr-display-line disp-lines
                                     (overlay-attr overlay)
                                     start-linum
                                     (point-linum start)
                                     (point-column start)
                                     (point-column end)))
             ((and (<= start-linum (point-linum start))
                   (< (point-linum end) end-linum))
              (set-attr-display-lines disp-lines
                                      (overlay-attr overlay)
                                      start-linum
                                      (point-linum start)
                                      (point-column start)
                                      (point-linum end)
                                      (point-column end)))
             ((<= (point-linum start)
                  start-linum
                  (point-linum end)
                  end-linum)
              (set-attr-display-lines disp-lines
                                      (overlay-attr overlay)
                                      start-linum
                                      start-linum
                                      0
                                      (point-linum end)
                                      (point-column end)))
             ((<= start-linum
                  (point-linum start))
              (set-attr-display-lines disp-lines
                                      (overlay-attr overlay)
                                      start-linum
                                      (point-linum start)
                                      (point-column start)
                                      end-linum
                                      nil)))))

(defun buffer-display-lines (buffer disp-lines start-linum nlines)
  (buffer-update-mark-overlay buffer)
  (let ((end-linum (+ start-linum nlines))
        (disp-nlines 0))
    (do ((line (buffer-get-line buffer start-linum)
               (line-next line))
         (i 0 (1+ i)))
        ((or (null line)
             (>= i nlines)))
      (incf disp-nlines)
      (setf (aref disp-lines i)
            (copy-fatstring (line-fatstr line))))
    (loop
      for i from disp-nlines below nlines
      do (setf (aref disp-lines i) nil))
    (display-lines-set-overlays disp-lines
                                (buffer-overlays buffer)
                                start-linum
                                end-linum)
    disp-lines))

(defun buffer-insert-char (buffer linum col c)
  (cond ((char= c #\newline)
         (buffer-insert-newline buffer linum col))
        (t
         (bt:with-lock-held (*editor-lock*)
           (buffer-read-only-guard buffer)
           (with-push-undo (buffer)
             (buffer-delete-char buffer linum col 1)
             (make-point linum col))
           (buffer-modify buffer)
           (let ((line (buffer-get-line buffer linum)))
             (dolist (marker (buffer-markers buffer))
               (when (and (= linum (marker-linum marker))
                          (< col (marker-column marker)))
                 (incf (marker-column marker))))
             (setf (line-fatstr line)
                   (fat-concat (fat-substring (line-fatstr line) 0 col)
                               (string c)
                               (fat-substring (line-fatstr line) col)))))))
  t)

(defun buffer-insert-newline (buffer linum col)
  (bt:with-lock-held (*editor-lock*)
    (buffer-read-only-guard buffer)
    (with-push-undo (buffer)
      (buffer-delete-char buffer linum col 1)
      (make-point linum col))
    (buffer-modify buffer)
    (dolist (marker (buffer-markers buffer))
      (cond
       ((and (= (marker-linum marker) linum)
             (< col (marker-column marker)))
        (incf (marker-linum marker))
        (decf (marker-column marker) col))
       ((< linum (marker-linum marker))
        (incf (marker-linum marker)))))
    (let ((line (buffer-get-line buffer linum)))
      (let ((newline
             (make-line line
                        (line-next line)
                        (fat-substring (line-fatstr line) col))))
        (when (eq line (buffer-tail-line buffer))
          (setf (buffer-tail-line buffer) newline))
        (setf (line-fatstr line)
              (fat-substring (line-fatstr line) 0 col))))
    (incf (buffer-nlines buffer))
    t))

(defun buffer-insert-line (buffer linum col str)
  (bt:with-lock-held (*editor-lock*)
    (buffer-read-only-guard buffer)
    (let ((line (buffer-get-line buffer linum)))
      (with-push-undo (buffer)
        (buffer-delete-char buffer linum col (fat-length str))
        (make-point linum col))
      (buffer-modify buffer)
      (dolist (marker (buffer-markers buffer))
        (when (and (= linum (marker-linum marker))
                   (<= col (marker-column marker)))
          (incf (marker-column marker) (fat-length str))))
      (setf (line-fatstr line)
            (fat-concat (fat-substring (line-fatstr line) 0 col)
                        str
                        (fat-substring (line-fatstr line) col))))
    t))

(defun buffer-delete-char (buffer linum col n)
  (bt:with-lock-held (*editor-lock*)
    (buffer-read-only-guard buffer)
    (let ((line (buffer-get-line buffer linum))
          (del-lines (list (make-fatstring "" 0)))
          (result t))
      (loop while (plusp n) do
        (cond
         ((<= n (- (fat-length (line-fatstr line)) col))
          (dolist (marker (buffer-markers buffer))
            (when (and (= linum (marker-linum marker))
                       (< col (marker-column marker)))
              (setf (marker-column marker)
                    (if (> col (- (marker-column marker) n))
                        col
                        (- (marker-column marker) n)))))
          (buffer-modify buffer)
          (setf (car del-lines)
                (fat-concat (car del-lines)
                            (fat-substring (line-fatstr line) col (+ col n))))
          (setf (line-fatstr line)
                (fat-concat (fat-substring (line-fatstr line) 0 col)
                            (fat-substring (line-fatstr line) (+ col n))))
          (setq n 0))
         (t
          (dolist (marker (buffer-markers buffer))
            (cond
             ((and (= linum (marker-linum marker))
                   (< col (marker-column marker)))
              (setf (marker-column marker) col))
             ((< linum (marker-linum marker))
              (decf (marker-linum marker)))))
          (setf (car del-lines)
                (fat-concat (car del-lines)
                            (fat-substring (line-fatstr line) col)))
          (push (make-fatstring "" 0) del-lines)
          (unless (line-next line)
            (setq result nil)
            (return nil))
          (decf n (1+ (- (fat-length (line-fatstr line)) col)))
          (decf (buffer-nlines buffer))
          (buffer-modify buffer)
          (setf (line-fatstr line)
                (fat-concat (fat-substring (line-fatstr line) 0 col)
                            (line-fatstr (line-next line))))
          (when (eq (line-next line)
                    (buffer-tail-line buffer))
            (setf (buffer-tail-line buffer) line))
          (line-free (line-next line)))))
      (setq del-lines
            (mapcar #'fat-string
                    (nreverse del-lines)))
      (with-push-undo (buffer)
        (let ((linum linum)
              (col col))
          (do ((rest del-lines (cdr rest)))
              ((null rest))
            (buffer-insert-line buffer linum col (car rest))
            (when (cdr rest)
              (buffer-insert-newline buffer linum
                                     (+ col (length (car rest))))
              (incf linum)
              (setq col 0)))
          (make-point linum col)))
      (values result del-lines))))

(defun buffer-erase (buffer)
  (bt:with-lock-held (*editor-lock*)
    (buffer-read-only-guard buffer)
    (buffer-modify buffer)
    (let ((line (make-line nil nil "")))
      (setf (buffer-head-line buffer) line)
      (setf (buffer-tail-line buffer) line)
      (setf (buffer-cache-line buffer) line)
      (setf (buffer-cache-linum buffer) 1)
      (setf (buffer-mark-p buffer) nil)
      (setf (buffer-mark-overlay buffer) nil)
      (setf (buffer-mark-marker buffer) nil)
      (setf (buffer-keep-binfo buffer) nil)
      (setf (buffer-nlines buffer) 1)
      (setf (buffer-overlays buffer) nil)
      (dolist (marker (buffer-markers buffer))
        (setf (marker-point marker) (make-point 1 0))))))

(defun buffer-check-marked (buffer)
  (cond ((buffer-mark-marker buffer) t)
        (t (minibuf-print "Not mark in this buffer")
           nil)))

(defun buffer-directory ()
  (if (buffer-filename)
      (directory-namestring
       (buffer-filename))
      (namestring (uiop:getcwd))))

(defun buffer-undo-modified (buffer)
  (when (= (buffer-undo-node buffer)
           (buffer-saved-node buffer))
    (setf (buffer-modified-p buffer) nil)))

(defun buffer-undo-1 (buffer)
  (let ((elt (pop (buffer-undo-stack buffer))))
    (when elt
      (let ((*undo-mode* :undo))
        (unless (eq elt :separator)
          (decf (buffer-undo-size buffer))
          (funcall elt))))))

(defun buffer-undo (buffer)
  (loop while (eq :separator (car (buffer-undo-stack buffer)))
    do (pop (buffer-undo-stack buffer)))
  (push :separator (buffer-redo-stack buffer))
  (prog1 (do ((res #1=(buffer-undo-1 buffer) #1#)
              (pres nil res))
             ((not res)
              (cond (pres
                     (decf (buffer-undo-node buffer))
                     (buffer-undo-modified buffer))
                    (t
                     (minibuf-print "Undo Error")))
              pres))))

(defun buffer-redo-1 (buffer)
  (let ((elt (pop (buffer-redo-stack buffer))))
    (when elt
      (let ((*undo-mode* :redo))
        (unless (eq elt :separator)
          (funcall elt))))))

(defun buffer-redo (buffer)
  (loop while (eq :separator (car (buffer-redo-stack buffer)))
    do (pop (buffer-redo-stack buffer)))
  (push :separator (buffer-undo-stack buffer))
  (prog1 (do ((res #1=(buffer-redo-1 buffer) #1#)
              (pres nil res))
             ((not res)
              (cond (pres
                     (incf (buffer-undo-node buffer))
                     (buffer-undo-modified buffer))
                    (t
                     (minibuf-print "Redo Error")))
              pres))))

(defun buffer-undo-boundary (&optional (buffer (window-buffer)))
  (push :separator (buffer-undo-stack buffer)))

(defun get-bvar (name &key (buffer (window-buffer)) default)
  (multiple-value-bind (value foundp)
      (gethash name (buffer-variables buffer))
    (if foundp value default)))

(defun (setf get-bvar) (value name &key (buffer (window-buffer)) default)
  (declare (ignore default))
  (setf (gethash name (buffer-variables buffer)) value))

(defun clear-buffer-variables (&key (buffer (window-buffer)))
  (clrhash (buffer-variables buffer)))
