;;; guard.el --- Custom modular init framework -*- lexical-binding: t -*-

;; Copyright (C) 2026 Dionisis Spiliopoulos

;; Author: Dionisis Spiliopoulos <dennisspiliopoylos@gmail.com>
;; URL: https://github.com/Dspil/guard.el
;; Version: 1.0.0
;; Keywords: convenience, initialization, profiles, tools
;; Package-Requires: ((emacs "29.1"))

;; SPDX-License-Identifier: GPL-3.0-or-later

;; Guard is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; Guard is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
;; License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with Guard.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; `guard' is a lightweight, graph-based init framework for managing Emacs
;; configuration modules.  It allows you to structure your `init.el` into
;; named, hierarchical sections, selectively enable or disable subsystems
;; and override behavior per machine.
;;
;; =============================================================================
;; 1. BASIC USAGE
;; =============================================================================
;;
;; Call `guard-initialize' early in your `init.el`.  Then call `guard-config' to
;; load the tweak-file.  Then wrap setup code in `guard-section' blocks:
;;
;;   (require 'guard)
;;   (guard-initialize)
;;   (guard-config) ; Loads local tweaks from `guard-tweak-file`
;;
;;   (guard-section ui ()
;;     "Various ui options"
;;     (tool-bar-mode -1)
;;     (scroll-bar-mode -1))
;;
;;   (guard-section themes (:parents (ui))
;;     (load-theme 'modus-vivendi t))
;;
;;
;; =============================================================================
;; 2. SECTION DEFINITION
;; =============================================================================
;;
;; A section is defined with:
;;
;; (guard-section [name] (<options>)
;;   <optional docstring>
;;   <optional body>)
;;
;; If a section starts with a string, that acts as its doscstring.
;;
;; =============================================================================
;; 3. DEPENDENCIES & INHERITANCE
;; =============================================================================
;;
;; A section can have any number of parent sections.
;;
;; Sub-sections can be declared explicitly via `:parents':
;;
;;   (guard-section Lisp (:parents (programming))
;;       (add-hook 'emacs-lisp-mode-hook #'enable-paredit-mode))
;;
;; or implicitly by nesting `guard-section` blocks within each other:
;;
;;   (guard-section programming ()
;;     (guard-section Lisp ()
;;       (add-hook 'emacs-lisp-mode-hook #'enable-paredit-mode)))
;;
;; The parents don't have to be declared beforehand.  If a section is first
;; introduced as a parent of a section currently being defined, the parent is
;; also defined at that moment.
;;
;; If a section has no parents, it's parent is either guard-parent-node or the
;; wrapping section (this has precedence).
;;
;; A section wrapped in an other section will always have the wrapping section
;; as a (maybe transitive) parent.
;;
;; =============================================================================
;; 4. Allowing/disallowing sections
;; =============================================================================
;;
;; Allowed sections will run during initialization and disallowed will not.
;;
;; A section is allowed either if it is *explicitly allowed* or if *all* of its
;; parents are allowed.
;; A section can also be *explicitly disallowed* in which case it is disallowed.
;;
;; All sections are transitive children of guard-parent-node which is by default
;; allowed.  This means that with no configuration, all sections are allowed.
;; Explicitly allowing/disallowing some section has the effect of allowing or
;; disallowing all transitive dependencies of the section.
;;
;; For explicitly allowing a section use `guard-allow':
;;
;;   (guard-allow (section1 ...)
;;     <optional body>)
;;
;; The symmetric is `guard-disallow' for explicitly disallowing a section:
;;
;;   (guard-disallow (section1 ...)
;;     <optional body>)
;;
;; Both these operations have a body which will run *after* explicitly allowing
;; or disallowing the argument sections.
;; This allows for allowing part of a tree easily like:
;;
;;   (guard-disallow (programming-languages)
;;     (guard-allow (python)))
;;
;; The above can be read as `Disallow all programming languages except python`.
;; Note that the above is also equivalent with:
;;
;;   (guard-disallow (programming-languages))
;;   (guard-allow (python))
;;
;; The optional body is just a visual convenienve.
;;
;; =============================================================================
;; 5. Mutually exclusive sections
;; =============================================================================
;;
;; A section can have the `:default-child' attribute:
;;
;;   (guard-section completion (:default-child vertico))
;;
;; `completion' is now a `xor` section and all of its children will be disabled
;; except `vertico'.
;; To override the chosen child (even though it is possible with `guard-allow'
;; and `guard-disallow' commands) you can use:
;;
;;   (guard-choose completion helm)
;;
;; This will make helm the default child.
;;
;; =============================================================================
;; 6. Overriding sections
;; =============================================================================
;;
;; A section can be overriden with:
;;
;;   (guard-override <place> <section>
;;     <body>)
;;
;; Here <place> can be:
;;   - `before': <body> will be executed before the code in the section
;;   - `after': <body> will be executed after the code in the section
;;   - `over': <body> will be executed instead of the code in the section
;;
;; =============================================================================
;; 7. Introspection
;; =============================================================================
;;
;; Run `M-x guard-dot` to open the `*guard-dot*` buffer containing a Graphviz DOT
;; representation of your configuration hierarchy.  This also contains runtime
;; information for each section during initialization.
;;
;; Run `M-x guard-look` to inspect the status of a section along with its
;; parents and children.
;;
;;; Code:

(require 'cl-lib)
(require 'subr-x)

;; Guard group and customizable variables

(defgroup guard nil
  "Custom modular init framework for toggling and overriding config sections."
  :group 'initialization
  :prefix "guard-")

(defcustom guard-parent-section 'all
  "The name of the base section that sections without a parent inherit from."
  :type 'symbol
  :group 'guard)

(defcustom guard-tweak-file (locate-user-emacs-file "init-tweak.el")
  "The file that contains machine-local configurations and overrides."
  :type 'file
  :group 'guard)

(defcustom guard-dot-prelude "
    rankdir=LR;

    /* Layout Optimizations */
    concentrate=true;
    splines=polyline;
    nodesep=0.5;
    ranksep=1.5;

    /* Default Node Styling */
    node [shape=box style=filled fontname=\"Helvetica\" fontsize=11];
    /* Default Edge Styling */
    edge [penwidth=2.0];
"
  "General settings of the dot graph."
  :type 'text
  :group 'guard)

;; Variables
(defvar guard--section-graph (make-hash-table) "Holds the section hierarchy.")
(defvar guard--sections-allowed (make-hash-table) "Holds which sections are enabled.")
(defvar guard--overrides (make-hash-table) "Holds overrides to sections.")
(defvar guard--init-times (make-hash-table) "Holds the amount of time each allowed section took during initialization.")
(defvar guard--neg-nodes (make-hash-table) "Holds the default child of each negative nodes.")
(defvar guard--node-stack nil "Stack of nested nodes.")
(defvar guard--nodes-with-subgraph (make-hash-table) "Which nodes have subgraphs.")
(defvar guard--node-places (make-hash-table) "Links to node definitions.")
(defvar guard--node-docs (make-hash-table) "Holds docstrings of sections.")
(defvar guard--node-params (make-hash-table) "Holds parameter overrides of nodes.")
(defvar-local guard--node-look-history '() "History for back button in `guard-look'.")
(defvar-local guard--node-looked nil "Section currently looked at.")
(defvar guard-after-jump-to-section-functions nil
  "Hook run after jumping to a section definition.
Functions receive (SECTION PLACE).")

;; Graph logic
(defun guard--section-parents (section)
  (car (gethash section guard--section-graph)))

(defun guard--section-children (section)
  (cdr (gethash section guard--section-graph)))

(defun guard--has-parent (section parent &optional parents)
  (cond
   ((eq section guard-parent-section) nil)
   ((member parent (or parents (guard--section-parents section))) t)
   (t (cl-some (lambda (p) (guard--has-parent p parent)) (or parents (guard--section-parents section))))))

(defun guard--graph-add-section (section maybe-parents file &optional parent-mode)
  (when (gethash section guard--section-graph)
    (error "Duplicate section %s\n" section))
  ;; Handle position data.
  (setf (gethash section guard--node-places) (cons file parent-mode))
  (let* ((stack-parent (when guard--node-stack (car guard--node-stack)))
         (all-parents (if (and stack-parent (not (guard--has-parent section stack-parent maybe-parents)))
                          (progn
                            (setf (gethash stack-parent guard--nodes-with-subgraph) t)
                            (cons stack-parent maybe-parents))
                        maybe-parents))
         (parents (or all-parents (list guard-parent-section))))
    ;; Parents first.
    (dolist (parent parents)
      ;; Create if they don't exist.
      (unless (gethash parent guard--section-graph)
	      (guard--graph-add-section parent nil file t))
      ;; Set their child.
      (setf (cdr (gethash parent guard--section-graph))
            (cons section (cdr (gethash parent guard--section-graph)))))
    ;; Initialize child.
    (setf (gethash section guard--section-graph)
          (cons parents '()))))

;; ================
;; Helper functions
;; ================

(defun guard--is-allowed (section &optional cache parent-mode from-child)
  "A section is allowed if it is explicitly set to be allowed or if *all* of its
parents are allowed. If a direct parent of the section is a negative node, it
has to be explicitly allowed. The CACHE should be a hash-table that also gets
updated with \='allowed or \='disallowed values for bulk operations."
  (let ((state (gethash section guard--sections-allowed))
        (cached-state (when cache (gethash section cache)))
        (neg-default (gethash section guard--neg-nodes)))
    (cond
     ((and parent-mode neg-default (not (eq neg-default from-child))) nil)
     ((or (eq state 'allowed) (eq cached-state 'allowed))
      (progn
        (when cache
          (setf (gethash section cache) 'allowed))
        t))
     ((or (eq state 'disallowed) (eq cached-state 'disallowed))
      (progn
        (when cache
          (setf (gethash section cache) 'disallowed))
        nil))
     (t
      (let ((parents (guard--section-parents section)))
        (if parents
            (let ((allowed
                   (cl-every (lambda (parent) (guard--is-allowed parent cache t section)) parents)))
              (when cache
                (setf (gethash section cache) (if allowed 'allowed 'disallowed)))
              allowed)
          t))))))

;; ===
;; DSL
;; ===

(defmacro guard-section (name options &rest body)
  (declare (indent defun)
           (doc-string 3))
  (let ((file (macroexp-file-name))
        (type-over (gethash name guard--overrides))
        (parents (make-symbol "parents"))
        (start-time (make-symbol "start-time"))
        (default-child (make-symbol "default-child")))
    (let ((section (if type-over
                       (let* ((where (car type-over))
                              (over (cdr type-over))
                              (first (if (or (equal where 'over) (equal where 'before)) over body))
                              (second (cond ((equal where 'over) nil)
                                            ((equal where 'before) body)
                                            ((equal where 'after) over))))
                         `(progn
                            ,@first
                            ,@second))
                     `(progn ,@body)))
          (docstring (and body (stringp (car body)) (car body))))
      `(progn
         (let ((,parents (plist-get ',options :parents))
               (,default-child (plist-get ',options :default-child)))
           (when ,default-child
             (unless (gethash ',name guard--neg-nodes)
               (setf (gethash ',name guard--neg-nodes) ,default-child)))
           (guard--graph-add-section ',name ,parents ,file))
         (setf (gethash ',name guard--node-docs) ,docstring)
         (when (guard--is-allowed ',name)
           (push ',name guard--node-stack)
           (let ((,start-time (current-time)))
             ,section
             (setf (gethash ',name guard--init-times)
                   (float-time (time-subtract (current-time)
                                              ,start-time)))
             (pop guard--node-stack)))))))

(defmacro guard-param (name &rest body)
  (let ((override (make-symbol "override"))
        (param-body (make-symbol "param-body")))
    `(let ((,override (and guard--node-stack (gethash (car guard--node-stack) guard--node-params))))
       (if ,override
           (let ((,param-body (gethash ',name ,override)))
             (if ,param-body
                 (eval (cons 'progn ,param-body))
               ,@body))
         ,@body))))

(defmacro guard-parameterize (name &rest body)
  (declare (indent 1))
  (unless (gethash name guard--node-params)
    (setf (gethash name guard--node-params) (make-hash-table)))
  (let ((params (gethash name guard--node-params)))
    (cl-loop for param-data in body
             for param-name = (car param-data)
             for param-body = (cdr param-data) do
             (setf (gethash param-name params) param-body))))

(defmacro guard-allow (sections &rest body)
  (declare (indent defun))
  (let ((secs (if (listp sections) sections (list sections))))
    `(progn
       (dolist (section ',secs)
         (puthash section 'allowed guard--sections-allowed))
       ,@body)))

(defmacro guard-disallow (sections &rest body)
  (declare (indent defun))
  (let ((secs (if (listp sections) sections (list sections))))
    `(progn
       (dolist (section ',secs)
         (puthash section 'disallowed guard--sections-allowed))
       ,@body)))

(defmacro guard-choose (section child)
  `(setf (gethash ',section guard--neg-nodes) ',child))

(defmacro guard-override (where name &rest body)
  "Override the section with name NAME.  WHERE can be \='over, \='before, \='after.
If it is \='over, the whole section will be overriden.  If it is \='before, the
override code will run before the section.  If it is \='after it will run after
the section."
  (declare (indent defun))
  `(progn
     (puthash ',name (cons ',where ',body) guard--overrides)))

;; guard utils

(defun guard-config ()
  (when (file-exists-p guard-tweak-file)
    (load guard-tweak-file)))

;; =============
;; introspection
;; =============

;; dot graph

(defun guard--format-duration (seconds)
  "Format SECONDS (float) into the shortest human-readable string."
  (let* ((us (* seconds 1000000.0))
         (str (cond
               ((< us 1000.0) (format "%.0fus" us))
               ((< us 1000000.0) (format "%.0fms" (/ us 1000.0)))
               ((< seconds 60.0) (format "%.1fs" seconds))
               ((< seconds 3600.0) (format "%.1fm" (/ seconds 60.0)))
               (t (format "%.1fh" (/ seconds 3600.0))))))
    (replace-regexp-in-string "\\.0\\([smh]\\)" "\\1" str)))

(defun guard--section-time (section)
  (guard--format-duration (gethash section guard--init-times)))

(defun guard--get-heatmap-color (ratio)
  "Calculate a hex color string between Light Yellow-Orange and Soft Coral Red.
RATIO is a float between 0.0 (fastest) and 1.0 (slowest)."
  (let* ((ratio (max 0.0 (min 1.0 ratio)))
         (r1 255) (g1 243) (b1 224)
         (r2 255) (g2 138) (b2 101)
         (r (round (+ r1 (* ratio (- r2 r1)))))
         (g (round (+ g1 (* ratio (- g2 g1)))))
         (b (round (+ b1 (* ratio (- b2 b1))))))
    (format "#%02x%02x%02x" r g b)))

(defun guard--dot-legend (min-time max-time)
  (format "    labelloc=\"b\";
    labeljust=\"c\";

    label=<
        <TABLE BORDER=\"0\" CELLBORDER=\"1\" CELLSPACING=\"0\" CELLPADDING=\"8\">
            <TR>
                <TD COLSPAN=\"2\" BORDER=\"0\" ALIGN=\"CENTER\"><B>Initialization Timing Heatmap</B></TD>
            </TR>
            <TR>
                <TD WIDTH=\"250\" HEIGHT=\"20\" BGCOLOR=\"#fff3e0:#ff8a65\" GRADIENTANGLE=\"0\"></TD>
            </TR>
            <TR>
                <TD BORDER=\"0\">
                    <TABLE BORDER=\"0\" CELLSPACING=\"0\" CELLPADDING=\"0\" WIDTH=\"100%%\">
                        <TR>
                            <TD ALIGN=\"LEFT\" BORDER=\"0\">%s (Min)</TD>
                            <TD ALIGN=\"RIGHT\" BORDER=\"0\">%s (Max)</TD>
                        </TR>
                    </TABLE>
                </TD>
            </TR>
        </TABLE>
        >;\n\n"
          (guard--format-duration min-time)
          (guard--format-duration max-time)))

(defun guard-dot ()
  "Generate a Graphviz DOT visualization of the configuration graph.
Populates the buffer `*guard-dot*' with a structural layout of all defined
sections, their initialization timings, and execution states, then attempts
to enable `graphviz-dot-mode'.

Below is a list of visual indicators in the graph.

1. Node Border Color (Execution Status):
   - Green: The section was allowed and ran.
   - Red: The section was disallowed/skipped.

2. Node Border Style (Subgraphs):
   - Solid: No section is defined inside this section.
   - Dashed: Sections are defined inside this section. These have this section
       as a parent by default. The initialization time of this node has an
       overlap with the children defined inside it.

2. Node Fill Color (Performance Heatmap):
   - Linear scale from Light Yellow-Orange (Fastest) to Red (Slowest)
   - White: Unexecuted or disabled sections.

3. Node Text Labels:
   - Every node displays its section name.
   - Allowed nodes append their run duration.

4. Node Shapes (Section Types):
   - Box: Standard section.
   - Diamond: Negative/conditional nodes that specify a `:default-child`.

5. Edge Styles (Dependency Paths):
   - Solid Line: Represents a standard parent-to-child inheritance path.
   - Dashed Line: Highlights a non-default routing path leading out from a
     conditional/negative node.
   - Black Arrow: Points to an active/allowed child section.
   - Gray Arrow: Points to an inactive/disallowed child section."
  (interactive)
  (pop-to-buffer "*guard-dot*")
  (erase-buffer)
  (insert "digraph G {\n")
  (insert guard-dot-prelude)
  (insert "\n")
  (let* ((cache (make-hash-table))
         (times (hash-table-values guard--init-times))
         (max-time (apply #'max times))
         (min-time (apply #'min times))
         (time-range (max 0.000001 (- max-time min-time))))
    (insert (guard--dot-legend min-time max-time))
    (cl-loop for section being the hash-keys of guard--section-graph
             unless (eq section guard-parent-section) do
             (let ((allowed (guard--is-allowed section cache))
                   (section-time (gethash section guard--init-times)))
               (insert
                (format
                 "    \"%s\" [penwidth=3.0 color=\"%s\" label=\"%s\" fillcolor=\"%s\"%s%s];\n"
                 section
                 (if allowed "green" "red")
                 (if (and allowed section-time)
                     (format "%s\n(%s)"
                             section
                             (guard--section-time section))
                   (format "%s" section))
                 (if (and allowed section-time)
                     (guard--get-heatmap-color
                      (/ (- section-time min-time)
                         time-range))
                   "#ffffff")
                 (if (gethash section guard--neg-nodes)
                     " shape=diamond"
                   "")
                 (if (gethash section guard--nodes-with-subgraph)
                     " style=\"dashed,filled\""
                   "")))))
    (cl-loop for section being the hash-keys of guard--section-graph
             unless (eq section guard-parent-section) do
             (dolist (child (guard--section-children section))
               (let* ((defchild (gethash section guard--neg-nodes))
                      (is-dashed (and defchild (not (eq child defchild))))
                      (child-allowed (guard--is-allowed child cache))
                      (edge-color (if child-allowed "black" "gray70")))
                 (insert (format "    \"%s\" -> \"%s\" [%s color=\"%s\"];\n"
                                 section
                                 child
                                 (if is-dashed "style=\"dashed\"" "")
                                 edge-color))))))
  (insert "}")
  (when (fboundp 'graphviz-dot-mode)
    (graphviz-dot-mode)))

;; section lookup

(defun guard--link-to-node (section)
  (let* ((data (gethash section guard--node-places))
         (place (car data))
         (is-parent (cdr data))
         (map (make-sparse-keymap)))
    (define-key map (kbd "RET")
                (lambda ()
                  (interactive)
                  (find-file place)
                  (goto-char (point-min))
                  (if is-parent
                      (re-search-forward
                       (format ":parents\\s-*([^)]*\\b%s\\b" section))
                    (re-search-forward
                     (format "(guard-section\\s-+%s[\s-(]" section)))
                  (beginning-of-line)
                  (run-hook-with-args 'guard-after-jump-to-section-functions
                                      section
                                      place)))
    (propertize (format "%s" place)
                'keymap map
                'face '(underline))))

(defun guard--enabled-status (section)
  (let ((explicit (gethash section guard--sections-allowed)))
    (cond
     ((eq explicit 'allowed) "explicitly allowed")
     ((eq explicit 'disallowed) "explicitly disallowed")
     (t (if (guard--is-allowed section) "allowed" "disallowed")))))

(defun guard--node-type (section)
  (if (gethash section guard--neg-nodes)
      "xor"
    "normal"))

(defun guard--node-link (section)
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET")
                (lambda ()
                  (interactive)
                  (guard-look section
                              (cons guard--node-looked guard--node-look-history))))
    (propertize (format "%s" section)
                'keymap map
                'face '(underline link))))

(defun guard--back-button ()
  (let ((map (make-sparse-keymap))
        (target-section (car guard--node-look-history))
        (remaining-history (cdr guard--node-look-history)))
    (define-key map (kbd "RET")
                (lambda ()
                  (interactive)
                  (guard-look target-section remaining-history)))
    (propertize (format "[Back to %s]" target-section)
                'keymap map
                'face '(underline link))))

(defun guard-look (&optional name prev-history)
  (interactive)
  (let ((section (or name
                     (intern-soft
                      (completing-read "Section: "
                                       (hash-table-keys guard--section-graph) nil t)))))
    (pop-to-buffer "*guard-section*")
    (setq-local guard--node-looked section)
    (setq-local guard--node-look-history prev-history)
    (read-only-mode -1)
    (erase-buffer)
    (insert (format "Section %s is defined in %s\n\n" section (guard--link-to-node section)))
    (insert (format "It is %s and %s.\n\n" (guard--node-type section) (guard--enabled-status section)))
    (let ((docstring (gethash section guard--node-docs)))
      (when docstring
        (insert (format "Documentation:\n"))
        (insert docstring)
        (insert "\n\n")))
    (let ((children (guard--section-children section)))
      (if children
          (progn
            (insert (format "Its children are:\n"))
            (cl-loop for child in children do
                     (insert (format "  - %s\n" (guard--node-link child)))))
        (insert "It has no children.\n")))
    (insert "\n")
    (let ((parents (guard--section-parents section)))
      (if parents
          (progn
            (insert (format "Its parents are:\n"))
            (cl-loop for parent in parents do
                     (insert (format "  - %s\n" (guard--node-link parent)))))
        (insert "It has no parents.\n")))
    (when guard--node-look-history
      (insert "\n")
      (insert (guard--back-button)))
    (read-only-mode nil)))

;; initialization method

(defun guard-initialize ()
  "Initialize the guard framework."
  (setf (gethash guard-parent-section guard--section-graph) (cons nil '())))

(provide 'guard)

;;; guard.el ends here
