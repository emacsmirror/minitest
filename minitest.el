;;; minitest.el --- An minor mode for ruby minitest files

;; Copyright © 2013-2015 Arthur Nogueira Neves
;; Copyright © 2020 Grant Shoshin Shangreaux

;; Author: Arthur Neves
;; URL: https://git.sr.ht/~shoshin/minitest-emacs
;; Version: 0.10.0
;; Package-Requires: ((dash "1.0.0") (emacs "24.3"))

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Use the following commands in minitest buffers to invoke the test runner
;; and get results in a compilation buffer:

;; minitest-verify
;; minitest-verify-single
;; minitest-rerun
;; minitest-verify-all

;;; Change Log:

;; 0.10.0 - No longer explicitly set compilation-scroll-output

;;; Code:

(require 'dash)
(require 'ansi-color)
(declare-function yas-load-directory "yasnippet")
(declare-function yas--load-pending-jits "yasnippet")
(defvar yas-snippet-dirs)

(defcustom minitest-keymap-prefix (kbd "C-c ,")
  "Minitest keymap prefix."
  :group 'minitest
  :type 'string)

(defcustom minitest-use-zeus-when-possible t
  "When t and .zeus.sock is present, run tests with zeus."
  :type 'boolean
  :group 'minitest)

(defcustom minitest-use-bundler t
  "Minitest mode should use bundler?"
  :type 'boolean
  :group 'minitest)

(defcustom minitest-use-spring nil
  "Use spring as the default runner."
  :type 'boolean
  :group 'minitest)

(defcustom minitest-use-rails nil
  "Use `bin/rails test' as the default runner.
This is intended for use with Rails versions 5+."
  :type 'boolean
  :group 'minitest)

(defcustom minitest-use-docker nil
  "Execute inside `minitest-docker-container' with `minitest-docker-command'."
  :type 'boolean
  :group 'minitest)

(defcustom minitest-docker-command '("docker-compose" "exec")
  "Command to execute tests with docker."
  :type 'list
  :group 'minitest)

(defcustom minitest-docker-container nil
  "Specify the name of the docker container to target."
  :type 'string
  :group 'minitest)

(defcustom minitest-default-env nil
  "Default env vars for minitest."
  :type 'string
  :group 'minitest)

(defcustom minitest-default-command '("ruby" "-Ilib:test:spec")
  "Default command for minitest."
  :type 'list
  :group 'minitest)

(defcustom minitest-spring-command '("spring" "rake" "test")
  "Spring command for minitest."
  :type 'list
  :group 'minitest)

(defcustom minitest-test-directory-name "test"
  "The folder name within `minitest-project-root' that holds the tests."
  :type 'string
  :group 'minitest)

(defcustom minitest-source-directory-names '("app" "lib")
  "The folder names within `minitest-project-root' that hold the source code."
  :type 'list
  :group 'minitest)

(defun minitest-buffer-name (file-or-dir)
  "Name for specific FILE-OR-DIR minitest compilation buffer."
  (concat "*Minitest " file-or-dir "*"))

(defun minitest-test-command ()
  "Return command to be used when invoking the test runner."
  (let ((command (cond (minitest-use-spring minitest-spring-command)
                       ((minitest-zeus-p) '("zeus" "test"))
                       (minitest-use-rails '("bin/rails" "test"))
                       (t minitest-default-command))))
    (if minitest-use-docker (append minitest-docker-command (list minitest-docker-container) command)
      command)))

(defun minitest-bundler-command ()
  "Return command strings for invoking Ruby's bundler."
  (cond (minitest-use-bundler '("bundle" "exec"))
        (t nil)))

(defun minitest-project-root ()
  "Retrieve the root directory of a project if available.
The current directory is assumed to be the project's root otherwise."
  (or (->> '("Rakefile" "Gemfile")
        (--map (locate-dominating-file default-directory it))
        (-remove #'null)
        (car))
      (error "You're not into a project")))

(defun minitest-zeus-p ()
  "Determine if the runner should use zeus."
  (and minitest-use-zeus-when-possible
       (file-exists-p (concat (minitest-project-root) ".zeus.sock"))))

(define-derived-mode minitest-compilation-mode compilation-mode ""
  (add-hook 'compilation-filter-hook 'minitest-colorize-compilation-buffer))

(defun minitest-colorize-compilation-buffer ()
  "Apply ansi color on the compilation buffer."
  (read-only-mode 1)
  (ansi-color-apply-on-region (point-min) (point-max))
  (read-only-mode -1))

(defvar minitest--last-command nil
  "Variable to store the last command running.")

(defun minitest--run-command (command &optional file-name)
  "Run COMMAND on current buffor or FILE-NAME."
  (if (fboundp 'rvm-activate-corresponding-ruby)
      (rvm-activate-corresponding-ruby))

  (let ((default-directory (minitest-project-root))
        (actual-command (concat (or minitest-default-env "") " " command)))
    (setq minitest--last-command (list command file-name))
    (compilation-start
     actual-command
     'minitest-compilation-mode
     (lambda (arg) (minitest-buffer-name (or file-name ""))))))

(defun minitest--file-command (&optional post-command)
  "Run POST-COMMAND on currently visited file."
  (let ((file-name (file-relative-name (buffer-file-name) (minitest-project-root))))
    (if file-name
	(minitest-run-file file-name post-command)
      (error "Buffer is not visiting a file"))))

(defun minitest--test-name-flag (test-name)
  "Return string identifying TEST-NAME."
  (let ((flag (format "-n/%s/" test-name)))
    (cond (minitest-use-spring (concat "TESTOPTS=" flag))
          (t flag))))

(defvar minitest--test-regexps
  '("\\(test\\) ['\"]\\([^\"]+?\\)['\"]"
    "def \\(test\\)_\\([_A-Za-z0-9]+\\)"
    "\\(it\\) \"\\([^\"]+?\\)\""
    "\\(it\\) '\\([^\"]+?\\)'")
  "List of regular expressions for minitest test definition patterns.")

(defun minitest--match-point (re)
  "Search for regular expression RE backwards from end of the current line.
Sets the `match-string' and returns the point where the match begins or nil."
  (save-excursion
    (save-restriction
      (widen)
      (end-of-line)
      (re-search-backward re nil t))))

(defun minitest--extract-test ()
  "Find the nearest test name matching one of the `minitest--test-regexps'.
Returns a (CMD . NAME) pair or nil."
  (let* ((matches (delete nil (mapcar 'minitest--match-point minitest--test-regexps)))
         (distances (mapcar (lambda (pos) (- (point) pos)) matches)))
    (if distances
        (let ((closest (cl-position (apply 'min distances) distances)))
          (minitest--match-point (nth closest minitest--test-regexps))
          `(,(match-string 1) . ,(match-string 2))))))

(defun minitest--verify-single-with-regex ()
  "Run verify command if a test is matched at point."
  (let ((test (minitest--extract-test)))
    (if test
        (minitest--file-command (minitest--test-name-flag (minitest--post-command test)))
      (error "No test found.  Make sure you are on a file that has `def test_foo` or `test \"foo\"`"))))

(defun minitest--verify-single-rails ()
  "Run `bin/rails test path/to/test_file.rb:NN' with the current line number."
  (let ((line-number (line-number-at-pos (point)))
        (file-name (file-relative-name (buffer-file-name) (minitest-project-root))))
    (minitest-run-file (format "%s:%s" file-name line-number))))

(defun minitest-verify-all ()
  "Run all test examples in the current project."
  (interactive)
  (minitest--run-command
    (mapconcat 'shell-quote-argument
               (-flatten
                (--remove (eq nil it)
                 (list (minitest-bundler-command) "rake"))) " ")))

(defun minitest-verify ()
  "Run on current file."
  (interactive)
  (minitest--file-command))

(defun minitest-verify-single ()
  "Run the test closest to the cursor, searching backwards."
  (interactive)
  (if minitest-use-rails (minitest--verify-single-rails)
    (minitest--verify-single-with-regex)))

(defun minitest--post-command (test)
  "Format the TEST name depending on spec or test style."
  (let ((name (cdr test)))
    (if (string= (car test) "it")
        name
      (format "%s" (replace-regexp-in-string "[\s#:]" "_" name)))))

(defun minitest-rerun ()
  "Run the last command."
  (interactive)
  (if minitest--last-command
      (apply #'minitest--run-command minitest--last-command)
    (error "There is no previous command to run")))

(defun minitest-run-file (file-name &optional post-command)
  "Run the given file FILE-NAME with optional POST-COMMAND specifier."
  (let ((bundle (minitest-bundler-command))
        (command (minitest-test-command)))
    (minitest--run-command
     (mapconcat 'shell-quote-argument
		(-flatten
		 (--remove (eq nil it)
			   (list bundle command file-name post-command))) " ")
     file-name)))

;;; Minor mode
(defvar minitest-mode-map
  (let ((map (make-sparse-keymap)))
    (let ((prefix-map (make-sparse-keymap)))
      (define-key prefix-map (kbd "a") 'minitest-verify-all)
      (define-key prefix-map (kbd "v") 'minitest-verify)
      (define-key prefix-map (kbd "s") 'minitest-verify-single)
      (define-key prefix-map (kbd "r") 'minitest-rerun)
      (define-key prefix-map (kbd "t") 'minitest-toggle-test-and-target)
      (define-key map minitest-keymap-prefix prefix-map))
    map)
  "Keymap for `minitest-mode'.")

;;;###autoload
(define-minor-mode minitest-mode
  "Minor mode for *_test (minitest) files."
  :lighter " Minitest"
  :keymap minitest-mode-map
  :group 'minitest
  (if minitest-mode
      (progn
        (when (boundp 'yas-extra-modes)
          (if (fboundp 'yas-activate-extra-mode)
              ;; Yasnippet 0.8.1+
              (yas-activate-extra-mode 'minitest-mode)
            (make-local-variable 'yas-extra-modes)
            (add-to-list 'yas-extra-modes 'minitest-mode)
            (yas--load-pending-jits))))))

(defvar minitest-snippets-dir
  (let ((current-file-name (or load-file-name (buffer-file-name))))
    (expand-file-name "snippets" (file-name-directory current-file-name)))
  "The directory containing minitest snippets.")

(defun minitest-install-snippets ()
  "Add `minitest-snippets-dir' to variable `yas-snippet-dirs' and load snippets."
  (interactive)
  (let ((yasnippet-available (require 'yasnippet nil t)))
    (if yasnippet-available
        (progn
          (add-to-list 'yas-snippet-dirs minitest-snippets-dir t)
          (yas-load-directory minitest-snippets-dir)))))

(defconst minitest-test-file-name-re "\\(_\\|-\\)test\\.rb\\'"
  "The regex to identify test files.")

(defun minitest-test-file-p (file-name)
  "Return non-nil if the specified FILE-NAME is a test."
  (numberp (string-match minitest-test-file-name-re file-name)))

(defun minitest-buffer-is-test-p ()
  "Return non-nil if the current buffer is a test."
  (and (buffer-file-name)
       (minitest-test-file-p (buffer-file-name))))

;;;###autoload
(defun minitest-toggle-test-and-target ()
  "Switch to the test or the target file for the current buffer.
If the current buffer is visiting a test file, switches to the
target, otherwise the test."
  (interactive)
  (find-file (minitest--test-or-target)))

(defun minitest--test-or-target ()
  "Return either the test file or implementation file related to current buffer."
  (if (minitest-buffer-is-test-p)
      (minitest--target-file-for (buffer-file-name))
    (minitest--test-file-for (buffer-file-name))))

(defun minitest--test-file-for (a-file-name)
  "Find test for A-FILE-NAME."
  (if (minitest-test-file-p a-file-name)
      a-file-name
    (let* ((replace-regex "^\\.\\./[^/]+/")
           (test-directory (concat (minitest-project-root) minitest-test-directory-name))
           (relative-file-name (file-relative-name a-file-name test-directory)))
      (minitest--testize-file-name (expand-file-name (replace-regexp-in-string replace-regex "" relative-file-name)
                                                    test-directory)))))

(defun minitest--target-file-for (a-test-file-name)
  "Find the target for A-TEST-FILE-NAME."
  (cl-loop for extension in (list "rb" "rake")
           for candidate = (minitest--targetize-file-name a-test-file-name
                                                         extension)
           for filename = (cl-loop for dir in (cons "." minitest-source-directory-names)
                                   for target = (replace-regexp-in-string
                                                 (concat "/" minitest-test-directory-name "/")
                                                 (concat "/" dir "/")
                                                 candidate)
                                   if (file-exists-p target)
                                   return target)
           if filename
           return filename))

(defun minitest--testize-file-name (a-file-name)
  "Return A-FILE-NAME but converted in to a test file name."
  (concat
   (file-name-directory a-file-name)
   (replace-regexp-in-string "\\(\\.\\(rb\\|rake\\)\\)?$" "_test.rb" (file-name-nondirectory a-file-name))))

(defun minitest--targetize-file-name (a-file-name extension)
  "Return A-FILE-NAME but converted into a non-test file name with EXTENSION."
  (concat (file-name-directory a-file-name)
          (minitest--file-name-with-default-extension
           (replace-regexp-in-string "_test\\.rb" (concat "." extension)
                                     (file-name-nondirectory a-file-name)))))

(defun minitest--file-name-with-default-extension (a-file-name)
  "Add .rb file extension to A-FILE-NAME if it does not already have an extension."
  (if (file-name-extension a-file-name)
      a-file-name ;; file has a extension already so do nothing
    (concat a-file-name ".rb")))

;;;###autoload
(defun minitest-enable-appropriate-mode ()
  "Enable `minitest-mode' if it is appropriate."
  (if (minitest-buffer-is-test-p)
      (minitest-mode)))

;;;###autoload
(dolist (hook '(ruby-mode-hook enh-ruby-mode-hook))
  (add-hook hook 'minitest-enable-appropriate-mode))

(provide 'minitest)
;;; minitest.el ends here
