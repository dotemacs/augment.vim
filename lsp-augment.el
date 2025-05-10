;;; lsp-augment.el --- lsp-mode client for Augment   -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Roland Dreier
;; MIT License - See LICENSE.md for full terms

;; Author: Roland Dreier <roland.dreier@gmail.com>
;; Package-Requires: ((emacs "27.1") (lsp-mode "6.2") (markdown-mode "2.3"))
;; Version: 0.1.0
;; Keywords: languages, tools
;; URL: https://github.com/rolandd/augment.vim

;;; Commentary:

;; LSP client for the Augment (https://www.augmentcode.com/) node server
;; Based on the vim client from https://github.com/augmentcode/augment.vim

;;; Code:

(require 'lsp-mode)
(require 'markdown-mode)

(defgroup lsp-augment nil
  "LSP support for Augment."
  :group 'lsp-mode
  :tag "Augment LSP"
  :link '(url-link "https://www.augmentcode.com"))

(defcustom lsp-augment-enabled nil
  "Enable Augment LSP client."
  :group 'lsp-augment
  :type 'boolean)

(defcustom lsp-augment-server-script
  (thread-last
    "lsp-augment"
    locate-library
    file-name-directory
    (expand-file-name "dist/server.js"))
  "Path to server script to run with node."
  :group 'lsp-augment
  :risky t
  :type 'file)

(defcustom lsp-augment-additional-context-folders nil
  "Additional directories that Augment should index and understand.
These directories help Augment provide better assistance by giving it
access to related code and context. For example, if you're working on a
module that depends on another project, you might want to add that
project's directory here."
  :group 'lsp-augment
  :type '(repeat directory))

(defcustom lsp-augment-applicable-fn (lambda (&rest _) lsp-augment-enabled)
  "A function that returns non-nil if Augment LSP should be enabled for the buffer.
The inputs are the file name and the major mode of the buffer."
  :type 'function
  :group 'lsp-augment)

(defcustom lsp-augment-chat-buffer-name "*Augment Chat History*"
  "Buffer name to be used for chats."
  :group 'lsp-augment
  :type 'string)

(defvar-local lsp-augment--chat-history nil
  "Chat history for the Augment buffer.")

(defvar lsp-augment--chat-mode 'buffer
  "The chat mode to use. Can be either 'buffer or 'comint.")

(defun lsp-augment-signin ()
  "Log into the Augment service."
  (interactive)
  (condition-case err
      (let ((signin-response (lsp-request "augment/login" nil)))
	(if (lsp-get signin-response :loggedIn)
	    (message "Already logged into Augment")
	  (progn
	    (browse-url (lsp-get signin-response :url))
	    (let ((auth-code (read-from-minibuffer (format "Please complete authentication in your browser...
%s

After authenticating, you will receive a code.
Paste the code in the prompt below.

Enter the authentication code: " (lsp-get signin-response :url)))))
	      (lsp-request "augment/token" (list :code auth-code))
	      (message "Successfully logged into Augment.")))))
    (error (message "Failed to sign in: %s" (error-message-string err)))))

(defun lsp-augment-signout ()
  "Log out of the Augment service."
  (interactive)
  (condition-case err
      (progn (lsp-request "augment/logout" nil)
	     (message "Signed out of Augment."))
    (error (message "Failed to sign out: %s" (error-message-string err)))))

(defun lsp-augment--chat-append-text (text)
  "Append text to the Augment chat buffer."
  (let ((buf-name lsp-augment-chat-buffer-name))
    (with-current-buffer (get-buffer-create buf-name)
      (unless (derived-mode-p 'markdown-view-mode)
	(markdown-view-mode))
      (save-excursion
	(let ((inhibit-read-only t))
	  (goto-char (point-max))
	  (insert text)))
      (display-buffer buf-name
		      '((display-buffer-reuse-window
			 display-buffer-pop-up-window)
			(reusable-frames . visible))))))

(defun lsp-augment--chat-append-message (message)
  "Append a user chat message to the Augment chat buffer."
  (lsp-augment--chat-append-text (format "================================================================================

	*You*

%s

--------------------------------------------------------------------------------

	*Augment*

" message)))

(lsp-defun lsp-augment--chat-chunk-handler (_workspace params)
  "Handler for `augment/chatChunk` notification."
  (let ((text (lsp-get params :text)))
    (if (eq lsp-augment--chat-mode 'buffer)
        (lsp-augment--chat-append-text text)
      (condition-case err
          (progn
            (message "DEBUG: Writing to shell buffer using write-output")
            (funcall (map-elt lsp-augment--current-shell :write-output) text))
        (error
         (message "Error writing to shell buffer: %s" (error-message-string err))
         ;; Fallback: try to write directly to the buffer
         ;; TODO: remove the hardcoded name & maybe remove this whole section
         (when-let ((buf (get-buffer "*augment-chat*")))
           (message "DEBUG: Fallback - writing directly to buffer")
           (with-current-buffer buf
             (let ((inhibit-read-only t))
               (goto-char (point-max))
               (insert text)))))))))

(defun lsp-augment--chat-response-handler (message response)
  "Update chat history when a response is received."
  (let ((text (lsp-get response :text))
	(request-id (lsp-get response :requestId))
	(buf (get-buffer lsp-augment-chat-buffer-name)))
    (when (and buf text request-id)
      (with-current-buffer buf
	(unless (local-variable-p 'lsp-augment--chat-history)
	  (set (make-local-variable 'lsp-augment--chat-history) []))
	(setq lsp-augment--chat-history
	      (vconcat lsp-augment--chat-history
		       `[(:request_message ,message
					   :response_text ,text
					   :request_id ,request-id)]))))))

(defun lsp-augment-find-workspace ()
  "Find an active Augment LSP workspace for the current buffer or any buffer."
  (or
   ;; First try to get the workspace for the current buffer
   (cl-find-if (lambda (ws)
                 (eq (lsp--client-server-id (lsp--workspace-client ws))
                     'augment-lsp-server))
               (lsp-workspaces))
   ;; If that fails, look for any Augment workspace in the session
   (cl-find-if (lambda (ws)
                 (eq (lsp--client-server-id (lsp--workspace-client ws))
                     'augment-lsp-server))
               (lsp--session-workspaces (lsp-session)))))

(defun lsp-augment-chat-buffer (message)
  "Send a message to Augment Code's buffer based chat, where the input is
entered into minibuffer."
  (condition-case err
      (let* ((chat-buf (get-buffer-create lsp-augment-chat-buffer-name))
             (workspace (lsp-augment-find-workspace))
             (chat-history (buffer-local-value 'lsp-augment--chat-history chat-buf))
             (buffer-type (when (local-variable-p 'lsp-augment--buffer-type)
                            (buffer-local-value 'lsp-augment--buffer-type (get-buffer chat-buf))))
             (document-position-params (if (and buffer-type (eq buffer-type 'chat))
                                           '(:textDocument (:uri "file:///dummy.txt")
                                                           :position (:line 0 :character 0))
                                         (lsp--text-document-position-params)))
             (chat-message (append (list :textDocumentPosition document-position-params
                                         :message message)
                                   (when (region-active-p)
                                     (list :selectedText
                                           (buffer-substring-no-properties (region-beginning) (region-end))))
                                   (when chat-history
                                     (list :history chat-history)))))
        (lsp-log "lsp-augment chat request: %s" (json-encode chat-message))
        (lsp-augment--chat-append-message message)
        (with-lsp-workspace workspace
          (lsp-request-async "augment/chat"
                             chat-message
                             (lambda (response)
                               (lsp-augment--chat-response-handler message response))
                             :error-handler (lambda (err)
                                              (message "Chat error: %s" (error-message-string err)))))
        (with-current-buffer chat-buf
          (unless (local-variable-p 'lsp-augment--buffer-type)
            (set (make-local-variable 'lsp-augment--buffer-type) 'chat))
          (unless (local-variable-p 'lsp-augment--workspace)
            (set (make-local-variable 'lsp-augment--workspace) workspace))))
    (error (message "Failed to send chat message: %s" (error-message-string err)))))

;; TODO: make it a buffer local variable!
(defvar lsp-augment--response-complete nil
  "Flag indicating whether the response is complete.")

;; TODO: this should probably be a buffer local variable also!
(defvar lsp-augment--current-shell nil
  "The current shell-maker shell being used for chat.")

(setq lsp-augment--chat-mode 'comint)

(defun lsp-augment-chat-comint ()
  "Start or switch to Augment chat using comint."
  (interactive)
  (condition-case err
      (progn
        ;; Hardcoding the buffer name for now.
        ;; But really this should be taken from a variable.
        ;; then it should be checked to see what type of chat is it,
        ;; buffer or comint.
        (if (get-buffer "*augment-chat*")
            (switch-to-buffer "*augment-chat*")
          ;; Otherwise start a new chat
          (let ((shell-maker-config
                 (make-shell-maker-config
                  :name "augment-chat"
                  :prompt "augment> "
                  :prompt-regexp "^augment> "
                  :execute-command
                  (lambda (command shell)
                    ;; Store the shell for the chat chunk handler to use
                    (setq lsp-augment--current-shell shell)
                    ;; really noisy, but detailed output
                    ;;(message "---> DEBUG: Set current shell to %s" shell)

                    ;; Display user message
                    ;; (funcall (map-elt shell :write-output)
                    ;;          (format "# You\n\n%s\n\n---\n\n# Augment\n\n" command))

                    ;; Prepare the chat message
                    (let* ((chat-message (list :message command))
                           (file-name nil)
                           (line-num 0)
                           (char-pos 0))

                      ;; Try to get file info from visible buffer
                      (when-let ((buf (get-buffer-window))
                                 (file-buf (and buf (window-buffer buf)))
                                 (buf-file-name (and file-buf (buffer-file-name file-buf))))
                        (with-current-buffer file-buf
                          (setq file-name buf-file-name
                                line-num (line-number-at-pos)
                                char-pos (- (point) (line-beginning-position)))))

                      ;; Add position info - use real file if available, otherwise use a dummy value
                      (if file-name
                          (setq chat-message
                                (append chat-message
                                        (list :textDocumentPosition
                                              (list :textDocument (list :uri (lsp--path-to-uri file-name))
                                                    :position (list :line (1- line-num)
                                                                    :character char-pos)))))
                        ;; Use a dummy value when no file is available
                        (setq chat-message
                              (append chat-message
                                      (list :textDocumentPosition
                                            (list :textDocument (list :uri "file:///dummy.txt")
                                                  :position (list :line 0 :character 0))))))

                      ;; Add selected text if region is active
                      (when (region-active-p)
                        (setq chat-message
                              (append chat-message
                                      (list :selectedText
                                            (buffer-substring-no-properties (region-beginning) (region-end))))))

                      ;; Find the active Augment workspace
                      (let ((workspace (lsp-augment-find-workspace)))
                        (if workspace
                            ;;(funcall (map-elt shell :write-output) "This works. \n")
                            (with-lsp-workspace workspace
                              ;; Send request to LSP server
                              (lsp-request-async
                               "augment/chat"
                               chat-message
                               (lambda (response)
                                 ;; Store response in history
                                 (let ((text (or (lsp-get response :text) ""))
                                       (request-id (or (lsp-get response :requestId) "unknown")))

                                   (message "DEBUG: Response complete, finishing output")

                                   ;; Safely finish the output
                                   (condition-case err
                                       (progn
                                         ;; Add newlines to separate response from prompt
                                         ;;(funcall (map-elt shell :write-output) "\n\n")
                                         ;; Just one newline as it looks better
                                         (funcall (map-elt shell :write-output) "\n")
                                         ;; Finish output to display prompt
                                         (funcall (map-elt shell :finish-output) t)
                                         ;;(message "---> DEBUG: %S" shell)
                                         ;; Force the buffer to be ready for input
                                         ;; (when (buffer-live-p (map-elt shell :buffer))
                                         ;;   (with-current-buffer (map-elt shell :buffer)
                                         ;;     (shell-maker--set-state (map-elt shell :buffer) 'ready)))
                                         )
                                     (error (message "Error in finish-output1: %s" (error-message-string err))))))
                               :error-handler (lambda (err)
                                                (message "DEBUG: Error handler called with: %S" err)
                                                (funcall (map-elt shell :write-output)
                                                         (format "Error: %s\n\n" (error-message-string err)))
                                                (funcall (map-elt shell :finish-output) nil))))
                          (funcall (map-elt shell :write-output)
                                   "Error: No active Augment LSP server found. Please open a file with an attached Augment server first.\n\n")
                          (funcall (map-elt shell :finish-output) nil)))))
                  :on-command-finished (lambda (_command _output shell)
                                         (message "DEBUG: Command finished callback called")
                                         ;;(spinner-stop)
                                         ;;;; Ensure prompt is visible and cursor is at the end
                                         ;;(when (buffer-live-p (map-elt shell :buffer))
                                         ;;  (with-current-buffer (map-elt shell :buffer)
                                         ;;    (goto-char (point-max))
                                         ;;    ;; Force shell-maker to be ready for input
                                         ;;    (shell-maker--set-state (map-elt shell :buffer) 'ready)))
                                         ))))
            (shell-maker-start shell-maker-config)))
        (message "Augment chat started. Type your message and press Enter."))
    (error (message "Failed to start chat: %s" (error-message-string err)))))

(defun lsp-augment-chat (&optional message)
  "Send a chat request to Augment."
  (interactive (when (eq lsp-augment--chat-mode 'buffer)
                 (list (read-string "Message: "))))
  (if (eq lsp-augment--chat-mode 'buffer)
      (lsp-augment-chat-buffer message)
    (lsp-augment-chat-comint)))

(defun lsp-augment-reset-chat ()
  "Clear the Augment chat history buffer and reset chat history."
  (interactive)
  (let ((buf-name "*Augment Chat History*"))
    (when (get-buffer buf-name)
      (with-current-buffer buf-name
	(let ((inhibit-read-only t))
	  (erase-buffer))
	(setq-local lsp-augment--chat-history nil)))))

(defun lsp-augment-status ()
  "Get the current status of the Augment service.
Returns a plist with status information from the server."
  (interactive)
  (condition-case err
      (let ((status-response
	     (lsp-request "augment/status" nil)))
	(when (called-interactively-p 'interactive)
	  (let ((login-status (if (lsp-get status-response :loggedIn)
				  "Signed in."
				"Not signed in."))
		(sync-status (when-let ((sync-percent (lsp-get status-response :syncPercentage)))
			       (format " (workspace %s%% synced)" sync-percent))))
	    (message "Augment%s: %s"
		     (or sync-status "")
		     login-status)))
	status-response)
    (error (message "Failed to get status: %s" (error-message-string err))
	   nil)))

(defun lsp-augment--server-command ()
  "Return the executable and command line arguments."
  ;;(list "python3" "/home/roland/proxy.py" (concat "node" " " lsp-augment-server-script " " "--stdio")))
  (list "node" lsp-augment-server-script "--stdio"))

(defun lsp-augment--server-initialization-options ()
  "Set initialization options to provide versioned user agent."
  (list :editor "emacs"
	:vimVersion emacs-version
	:pluginVersion "emacs 0.1.0"))

(defun lsp-augment--get-workspace-folders ()
  "Convert workspace folders to LSP format."
  (when lsp-augment-additional-context-folders
    (mapcar (lambda (folder)
              (list :uri (lsp--path-to-uri folder)
                    :name (file-name-nondirectory (directory-file-name folder))))
            lsp-augment-additional-context-folders)))

(defun lsp-augment--custom-capabilities ()
  "Add workspace folders to initialization request."
  (or (when-let* ((folders (lsp-augment--get-workspace-folders))
                  ((> (length folders) 0)))
        `(:workspaceFolders ,folders))
      '()))

(lsp-register-client
 (make-lsp-client
  :new-connection (lsp-stdio-connection #'lsp-augment--server-command)
  :activation-fn lsp-augment-applicable-fn
  :server-id 'augment-lsp-server
  :multi-root t
  :add-on? t
  :completion-in-comments? t
  :initialization-options #'lsp-augment--server-initialization-options
  :custom-capabilities (lsp-augment--custom-capabilities)
  :notification-handlers (lsp-ht
			  ("augment/chatChunk" #'lsp-augment--chat-chunk-handler))))

(defun lsp-augment--completion-modify-response (resp)
  "Modify the completion response RESP before processing."
  (let ((items (if (lsp-completion-list? resp)
		   (lsp:completion-list-items resp)
		 resp)))
    ;; Filter out empty completions
    (setq items
	  (cl-remove-if
	   (lambda (item)
	     (let ((insert-text (lsp:completion-item-insert-text? item)))
	       (and insert-text (string-empty-p insert-text))))
	   items))

    ;; Convert insertText items to textEdit
    (dolist (item items)
      (when-let* ((insert-text (lsp:completion-item-insert-text? item)))
	  (lsp:set-completion-item-label item insert-text)

	  (unless (lsp:completion-item-text-edit? item)
	    (let* ((position (lsp-make-position :line (lsp--cur-line)
						:character (- (point) (line-beginning-position))))
		   (range (lsp-make-range :start position :end position))
		   (text-edit (lsp-make-text-edit :range range :new-text insert-text)))
	      (lsp:set-completion-item-text-edit? item text-edit)
	      (lsp:set-completion-item-insert-text? item nil))))))
    resp)

(defun lsp-augment--completion-advice (orig-fun method params &rest args)
  "Advice around lsp-request-while-no-input' to fix completion response for emacs."
  (if (string= method "textDocument/completion")
      (let ((response (apply orig-fun method params args)))
	(lsp-augment--completion-modify-response response))
    (apply orig-fun method params args)))

(advice-add 'lsp-request-while-no-input :around #'lsp-augment--completion-advice)

(provide 'lsp-augment)
;;; lsp-augment.el ends here
