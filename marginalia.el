;;; marginalia.el --- Enrich existing commands with completion annotations -*- lexical-binding: t -*-

;; Author: Omar Antolín Camarena, Daniel Mendler
;; Maintainer: Omar Antolín Camarena, Daniel Mendler
;; Created: 2020
;; License: GPL-3.0-or-later
;; Version: 0.1
;; Package-Requires: ((emacs "26.1"))
;; Homepage: https://github.com/minad/marginalia

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Enrich existing commands with completion annotations

;;; Code:

(require 'subr-x)
(eval-when-compile (require 'cl-lib))

;;;; Customization

(defgroup marginalia nil
  "Enrich existing commands with completion annotations."
  :group 'convenience
  :prefix "marginalia-")

(defface marginalia-key
  '((t :inherit font-lock-keyword-face :weight normal))
  "Face used to highlight keys in `marginalia-mode'."
  :group 'marginalia)

(defface marginalia-variable
  '((t :inherit marginalia-key))
  "Face used to highlight variable values in `marginalia-mode'."
  :group 'marginalia)

(defface marginalia-annotation
  '((t :inherit completions-annotations :weight normal))
  "Face used to highlight documentation string in `marginalia-mode'."
  :group 'marginalia)

(defcustom marginalia-annotation-width 80
  "Width of annotation string."
  :type 'integer
  :group 'marginalia)

(defcustom marginalia-annotator-alist
  '((command . marginalia-annotate-command-binding)
    (customize-group . marginalia-annotate-customize-group)
    (variable . marginalia-annotate-variable)
    (face . marginalia-annotate-face)
    (symbol . marginalia-annotate-symbol)
    (variable . marginalia-annotate-variable)
    (package . marginalia-annotate-package))
  "Associate categories with annotators for minibuffer completion.
Each annotation function must return a string,
which is appended to the completion candidate.
Annotations are only shown if `marginalia-mode' is enabled."
  :type '(alist :key-type symbol :value-type function)
  :group 'marginalia)

(defcustom marginalia-classifiers
  '(marginalia-classify-by-command-name
    marginalia-classify-original-category
    marginalia-classify-by-prompt
    marginalia-classify-symbol)
  "List of functions to determine current completion category.
Each function should take no arguments and return a symbol
indicating the category, or nil to indicate it could not
determine it."
  :type 'hook
  :group 'marginalia)

(defcustom marginalia-prompt-categories
  '(("\\<group\\>" . customize-group)
    ("\\<M-x\\>" . command)
    ("\\<package\\>" . package)
    ("\\<face\\>" . face)
    ("\\<variable\\>" . variable))
  "Associates regexps to match against minibuffer prompts with categories."
  :type '(alist :key-type regexp :value-type symbol)
  :group 'marginalia)

(defcustom marginalia-command-category-alist nil
  "Associate commands with a completion category."
  :type '(alist :key-type symbol :value-type symbol)
  :group 'marginalia)

;;;; Pre-declarations for external packages

(defvar package--builtins)
(defvar package-alist)
(defvar package-archive-contents)
(declare-function package-desc-summary "package")
(declare-function package--from-builtin "package")

;;;; Marginalia mode

(defvar marginalia--this-command nil
  "Last command symbol saved in order to allow annotations.")

(defvar marginalia--original-category nil
  "Original category reported by completion metadata.")

(defun marginalia--truncate (str width)
  "Truncate string STR to WIDTH."
  (truncate-string-to-width (car (split-string str "\n")) width 0 32 "…"))

(defun marginalia-annotate-command-binding (cand)
  "Annotate command CAND with keybinding."
  ;; Taken from Emacs 28, read-extended-command--annotation
  (when-let* ((binding
               (with-current-buffer (window-buffer (minibuffer-selected-window))
                 (where-is-internal (intern cand) overriding-local-map t)))
              (desc (and (not (stringp binding)) (key-description binding))))
    (propertize (format " (%s)" desc) 'face 'marginalia-key)))

(defun marginalia-annotate-command-full (cand)
  "Annotate command CAND with the keybinding and its documentation string."
  (concat
   (marginalia-annotate-command-binding cand)
   (marginalia-annotate-symbol cand)))

(defun marginalia--annotation (ann)
  "Format annotation string ANN."
  (concat " "
          (propertize
           " "
           'display
           '(space :align-to (- right-fringe marginalia-annotation-width)))
          (propertize (marginalia--truncate ann marginalia-annotation-width)
                      'face 'marginalia-annotation)))

(defun marginalia-annotate-symbol (cand)
  "Annotate symbol CAND with its documentation string."
  (when-let (doc (let ((sym (intern cand)))
                   (cond
                    ((fboundp sym) (ignore-errors (documentation sym)))
                    ((facep sym) (documentation-property sym 'face-documentation))
                    (t (documentation-property sym 'variable-documentation)))))
    (marginalia--annotation doc)))

(defun marginalia-annotate-variable (cand)
  "Annotate variable CAND with its documentation string."
  (let ((sym (intern cand)))
    (when-let (doc (documentation-property sym 'variable-documentation))
      (concat " "
              (propertize
               " "
               'display
               '(space :align-to (- right-fringe marginalia-annotation-width 30)))
              (propertize (marginalia--truncate (format "%S" (if (boundp sym)
                                                              (symbol-value sym)
                                                            'unbound))
                                             40)
                          'face 'marginalia-variable)
              "    "
              (propertize (marginalia--truncate doc marginalia-annotation-width)
                          'face 'marginalia-annotation)))))

(defun marginalia-annotate-face (cand)
  "Annotate face CAND with documentation string and face example."
  (let ((sym (intern cand)))
    (when-let (doc (documentation-property sym 'face-documentation))
      (concat " "
              (propertize
               " "
               'display
               '(space :align-to (- right-fringe marginalia-annotation-width 30)))
              (propertize "abcdefghijklmNOPQRSTUVWXYZ" 'face sym)
              "    "
              (propertize (marginalia--truncate doc marginalia-annotation-width)
                          'face 'marginalia-annotation)))))

(defun marginalia-annotate-package (cand)
  "Annotate package CAND with its description summary."
  (when-let* ((pkg (intern (replace-regexp-in-string "-[[:digit:]\\.-]+$" "" cand)))
              ;; taken from embark.el, originally `describe-package-1`
              (desc (or (car (alist-get pkg package-alist))
                        (if-let ((built-in (assq pkg package--builtins)))
                            (package--from-builtin built-in)
                          (car (alist-get pkg package-archive-contents))))))
    (marginalia--annotation (package-desc-summary desc))))

(defun marginalia-annotate-customize-group (cand)
  "Annotate customization group CAND with its documentation string."
  (when-let (doc (documentation-property (intern cand) 'group-documentation))
    (marginalia--annotation doc)))

(defun marginalia-classify-by-command-name ()
  "Lookup category for current command."
  (and marginalia--this-command
       (alist-get marginalia--this-command marginalia-command-category-alist)))

(defun marginalia-classify-original-category ()
  "Return original category reported by completion metadata."
  marginalia--original-category)

(defun marginalia-classify-symbol ()
  "Determine if currently completing symbols."
  (when-let ((mct minibuffer-completion-table))
    (when (or (eq mct 'help--symbol-completion-table)
              (obarrayp mct)
              (and (consp mct) (symbolp (car mct))) ; assume list of symbols
              ;; imenu from an Emacs Lisp buffer produces symbols
              (and (eq marginalia--this-command 'imenu)
                   (with-current-buffer
                       (window-buffer (minibuffer-selected-window))
                     (derived-mode-p 'emacs-lisp-mode))))
      'symbol)))

(defun marginalia-classify-by-prompt ()
  "Determine category by matching regexps against the minibuffer prompt.
This runs through the `marginalia-prompt-categories' alist
looking for a regexp that matches the prompt."
  (when-let ((prompt (minibuffer-prompt)))
    (cl-loop for (regexp . category) in marginalia-prompt-categories
             when (string-match-p regexp prompt)
             return category)))

(defun marginalia--completion-metadata-get (metadata prop)
  "Advice for `completion-metadata-get'.
Replaces the category and annotation function.
METADATA is the metadata.
PROP is the property which is looked up."
  (pcase prop
    ('annotation-function
     (when-let (cat (completion-metadata-get metadata 'category))
       ;; we do want the advice triggered for completion-metadata-get
       (alist-get cat marginalia-annotator-alist)))
    ('category
     (let ((marginalia--original-category (alist-get 'category metadata)))
       ;; using alist-get in the line above bypasses any advice on
       ;; completion-metadata-get to avoid infinite recursion
       (run-hook-with-args-until-success 'marginalia-classifiers)))))

(defun marginalia--minibuffer-setup ()
  "Setup minibuffer for `marginalia-mode'.
Remember `this-command' for annotation."
  (setq-local marginalia--this-command this-command))

;;;###autoload
(define-minor-mode marginalia-mode
  "Annotate completion candidates with richer information."
  :global t

  ;; Reset first to get a clean slate.
  (advice-remove #'completion-metadata-get #'marginalia--completion-metadata-get)
  (remove-hook 'minibuffer-setup-hook #'marginalia--minibuffer-setup)

  ;; Now add our tweaks.
  (when marginalia-mode
    ;; Ensure that we remember this-command in order to select the annotation function.
    (add-hook 'minibuffer-setup-hook #'marginalia--minibuffer-setup)

    ;; Replace the metadata function.
    (advice-add #'completion-metadata-get :before-until #'marginalia--completion-metadata-get)))

;;;###autoload
(defun marginalia-set-command-annotator (cmd ann)
  "Configure marginalia so that annotator ANN is used for command CMD."
  (setq marginalia-command-category-alist
        (cons (cons cmd cmd)
              (assq-delete-all cmd marginalia-command-category-alist)))
  (setq marginalia-command-category-alist
        (cons (cons cmd ann)
              (assq-delete-all cmd marginalia-annotator-alist))))

(provide 'marginalia)
;;; marginalia.el ends here
