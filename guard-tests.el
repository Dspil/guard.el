;;; guard-tests.el --- Tests for guard.el -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'guard)

(defmacro guard-with-clean-state (&rest body)
  "Run test in cleared global state.
BODY should be a test."
  `(let ((guard--section-graph (make-hash-table))
         (guard--sections-allowed (make-hash-table))
         (guard--overrides (make-hash-table))
         (guard--init-times (make-hash-table))
         (guard--neg-nodes (make-hash-table))
         (guard--node-stack nil)
         (guard--nodes-with-subgraph (make-hash-table))
         (guard--node-places (make-hash-table))
         (guard--node-docs (make-hash-table))
         (guard--node-params (make-hash-table)))
     (guard-initialize)
     ,@body))

(ert-deftest guard-test-section-definition ()
  "Test defining a section and checking implicit allow state."
  (guard-with-clean-state
   (guard-section ui ()
     "UI settings")
   
   ;; Verify section was added to the graph
   (should (gethash 'ui guard--section-graph))
   ;; Verify section is allowed by default
   (should (guard--is-allowed 'ui))))

(ert-deftest guard-test-disallow-and-allow ()
  "Test explicitly disallowing and allowing sections."
  (guard-with-clean-state
   (guard-section programming ())
   (guard-section lisp (:parents (programming)))

   ;; Explicitly disallow programming
   (guard-disallow (programming))
   (should-not (guard--is-allowed 'programming))
   ;; Child should inherit disallowed state
   (should-not (guard--is-allowed 'lisp))

   ;; Explicitly allow child
   (guard-allow (lisp))
   (should (guard--is-allowed 'lisp))))

(ert-deftest guard-test-default-child ()
  "Test XOR section behavior with default child."
  (guard-with-clean-state
   (guard-section completion (:default-child vertico))
   (guard-section vertico (:parents (completion)))
   (guard-section helm (:parents (completion)))

   ;; Vertico should be allowed as default child
   (should (guard--is-allowed 'vertico))
   ;; Helm should NOT be allowed
   (should-not (guard--is-allowed 'helm))

   ;; Switch default child to helm using guard-choose
   (guard-choose completion helm)
   (should (guard--is-allowed 'helm))
   (should-not (guard--is-allowed 'vertico))))

(ert-deftest guard-test-multiple-inheritance ()
  "Test multiple inheritance rule."
  (guard-with-clean-state
   (guard-section child (:parents (parent1 parent2)))

   (should (guard--is-allowed 'child))

   ;; Disable one of the parents
   (guard-disallow parent1)

   ;; Now child should not be allowed
   (should-not (guard--is-allowed 'child))))

(ert-deftest guard-test-transitive-inheritance ()
  "Test transitive inheritance scenario."
  (guard-with-clean-state
   (guard-section grandparent ())
   (guard-section parent (:parents (grandparent)))
   (guard-section child (:parents (parent)))
   (guard-section grandchild (:parents (child)))

   ;; Disable the grandparent
   (guard-disallow grandparent)

   ;; Grandchild should be disabled
   (should-not (guard--is-allowed 'grandchild))))

(ert-deftest guard-test-duplicate-section-error ()
  "Test throwing an error on duplicate sections."
  (guard-with-clean-state
   (guard-section foo ())
   (should-error
    (guard-section foo ()))))

(ert-deftest guard-test-disallow-overriding ()
  "Test overriding a disallow."
  (guard-with-clean-state
   (guard-section foo ())
   ;; Disable the section
   (guard-disallow foo)

   ;; Enable the section
   (guard-allow foo)

   ;; Section should be enabled
   (should (guard--is-allowed 'foo))))

(ert-deftest guard-test-allowed-executes ()
  "Test whether an allowed section executes."
  (guard-with-clean-state
   (let ((flag nil))

     ;; foo is allowed by default
     (guard-section foo ()
       (setq flag t))
     (should flag))))

(ert-deftest guard-test-disallowed-does-not-execute ()
  "Test whether an allowed section executes."
  (guard-with-clean-state
   (let ((flag t))

     ;; Disallow foo
     (guard-disallow foo)
     (guard-section foo ()
       (setq flag nil))
     (should flag))))

(provide 'guard-tests)

;;; guard-tests.el ends here
