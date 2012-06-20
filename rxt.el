;; rxt.el -- PCRE <-> Elisp <-> rx/SRE regexp syntax converter

;; Copyright (C) 2012 Jonathan Oddie

;;
;; Author:			j.j.oddie at gmail.com
;; Created:			4 June 2012
;; Updated:			13 June 2012

;; This file is NOT part of GNU Emacs.

;; This program is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see `http://www.gnu.org/licenses/'.

;; This file incorporates work covered by the following copyright and  
;; permission notice: 
;;
;; Copyright (c) 1993-2002 Richard Kelsey and Jonathan Rees Copyright
;; (c) 1994-2002 by Olin Shivers and Brian D. Carlstrom. Copyright (c)
;; 1999-2002 by Martin Gasbichler. Copyright (c) 2001-2002 by Michael
;; Sperber.  All rights reserved.
;;
;; Redistribution and use in source and binary forms, with or without
;; modification, are permitted provided that the following conditions
;; are met: 1. Redistributions of source code must retain the above
;; copyright notice, this list of conditions and the following
;; disclaimer. 2. Redistributions in binary form must reproduce the
;; above copyright notice, this list of conditions and the following
;; disclaimer in the documentation and/or other materials provided
;; with the distribution. 3. The name of the authors may not be used
;; to endorse or promote products derived from this software without
;; specific prior written permission.
;;
;; THIS SOFTWARE IS PROVIDED BY THE AUTHORS "AS IS" AND ANY EXPRESS OR
;; IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
;; WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
;; ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY
;; DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
;; DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
;; GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
;; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
;; WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;; NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;; SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.



;;; Commentary:

;; This library provides support for translating regexp syntax back
;; and forth between Emacs regular expressions, a limited subset of
;; PCRE (Perl Compatible Regular Expressions), and the S-expression
;; based `rx' and SRE forms.  More specifically, it provides an
;; abstract data type (ADT) for representing regular expressions,
;; parsers from PCRE and Elisp string notation to the, and "unparsers"
;; from the ADT to PCRE, `rx', and SRE syntaxes. (Conversion back to
;; Elisp regexps is handled in two steps, first to `rx' syntax, and
;; then using `rx-to-string' from the `rx' library).
;;
;; The main functions of interest are `rxt-elisp->rx',
;; `rxt-elisp->sre', `rxt-pcre->rx', `rxt-pcre->sre',
;; `rxt-pcre->elisp', and `rxt-elisp->pcre'. Additionally, various
;; bits of the RE-Builder package are re-defined in a blatantly
;; non-modular manner to support (emulated) PCRE syntax and conversion
;; back and forth between PCRE, Elisp and rx syntax. (TODO: fix this.)
;;
;; The more low-level functions are the parser `rxt-parse-re', which
;; produces an abstract syntax tree from a string in Elisp or PCRE
;; form, and the unparsers `rxt-adt->pcre', `rxt-adt->rx', and
;; `rxt-adt->sre'. Finally, there is also a simple function to
;; generate a list of all strings matched by a finite regexp (one with
;; no unbounded quantifiers +, *, etc.): `rxt-elisp->strings' and
;; `rxt-pcre->strings'. This could be useful if you have an expression
;; produced by `regexp-opt' and want to get back the original set of
;; strings.
;;
;; This code is partially based on Olin Shivers' reference SRE
;; implementation in scsh: see scsh/re.scm, scsh/spencer.scm and
;; scsh/posixstr.scm. In particular, it steals the idea of an abstract
;; data type for regular expressions and the general structure of the
;; string regexp parser and unparser. The data types for character
;; sets are extended in order to support symbolic translation between
;; character set expressions without assuming a small (Latin1)
;; character set. The string parser is also extended to parse a bigger
;; variety of constructions, including POSIX character classes and
;; various Emacs and Perl regexp assertions. Otherwise, only the bare
;; minimum of SRE's abstract data type is implemented: in particular,
;; regexps do not count their submatches.
;;
;;
;; BUGS AND LIMITATIONS:
;; - Although the string parser tries to interpret PCRE's octal and
;;   hexadecimal escapes correctly, there are problems with matching
;;   non-ASCII chars that I don't use enough to properly understand:
;;   e.g., (string-match-p (rxt-pcre->elisp "\\377") "\377") => nil
;;
;; - Most of PCRE's rules for how ^, \A, $ and \Z interact with
;;   newlines in a string are not implemented; they don't seem as
;;   relevant to Emacs's buffer-oriented rather than
;;   string/line-oriented model.
;;
;; - Many more esoteric PCRE features will never be supported because
;;   they can't be emulated by translation to Elisp regexps. These
;;   include the different lookaround assertions, conditionals, and
;;   the "backtracking control verbs" (* ...) .
;;
;; TODO:
;; - PCRE \g{...}
;; - PCREs in isearch mode
;; - many other things

(require 'cl)
(require 'rx)
(require 're-builder)


;;; Scanner macro
(eval-when-compile
  (defmacro rxt-token-case (&rest cases)
    "Consume a token at point and evaluate corresponding forms.

CASES is a list of `cond'-like clauses, (REGEXP FORMS
...). Considering CASES in order, if the text at point matches
REGEXP then moves point over the matched string and returns the
value of FORMS. Returns `nil' if none of the CASES matches."
    (declare (debug (&rest (sexp &rest form))))
    `(cond
      ,@(mapcar
	 (lambda (case)
	   (let ((token (car case))
		 (action (cdr case)))
	     (if (eq token t)
		 `(t ,@action)
	       `((looking-at ,token)
		 (goto-char (match-end 0))
		 ,@action))))
	 cases))))


;;;; Regexp ADT

;;; Strings
(defstruct
  (rxt-string
   (:constructor rxt-string (chars)))
  chars)

(defvar rxt-empty-string (rxt-string ""))
(defvar rxt-trivial rxt-empty-string)

(defun rxt-trivial-p (re)
  (and (rxt-string-p re)
       (equal (rxt-string-chars re) "")))

;;; Other primitives
(defstruct (rxt-primitive
	    (:constructor rxt-primitive (pcre rx &optional (sre rx))))
  pcre rx sre)

(defvar rxt-bos (rxt-primitive "\\A" 'bos))
(defvar rxt-eos (rxt-primitive "\\Z" 'eos))

(defvar rxt-bol (rxt-primitive "^" 'bol))
(defvar rxt-eol (rxt-primitive "$" 'eol))

;; FIXME
(defvar rxt-anything (rxt-primitive "." 'anything))
(defvar rxt-nonl (rxt-primitive "." 'nonl))

(defvar rxt-word-boundary (rxt-primitive "\\b" 'word-boundary))
(defvar rxt-not-word-boundary (rxt-primitive "\\B" 'not-word-boundary))

(defvar rxt-wordchar (rxt-primitive "\\w" 'wordchar))
(defvar rxt-not-wordchar (rxt-primitive "\\W" 'not-wordchar))

(defvar rxt-symbol-start (rxt-primitive nil 'symbol-start))
(defvar rxt-symbol-end (rxt-primitive nil 'symbol-end))

(defvar rxt-bow (rxt-primitive nil 'bow))
(defvar rxt-eow (rxt-primitive nil 'eow))


;;; Sequence
(defstruct
  (rxt-seq
   (:constructor make-rxt-seq (elts)))
  elts)

;; Slightly smart sequence constructor:
;; - Flattens nested sequences
;; - Drops trivial "" elements
;; - Empty sequence => ""
;; - Singleton sequence is reduced to its one element.
(defun rxt-seq (res)		    ; Flatten nested seqs & drop ""'s.
  (let ((res (rxt-seq-flatten res)))
    (if (consp res)
	(if (consp (cdr res))
	    (make-rxt-seq res)		; General case
	  (car res))			; Singleton sequence
      rxt-trivial)))			; Empty seq -- ""

(defun rxt-seq-flatten (res)
  (if (consp res)
      (let ((re (car res))
	    (tail (rxt-seq-flatten (cdr res))))
	(cond ((rxt-seq-p re)		; Flatten nested seqs
	       (append (rxt-seq-flatten (rxt-seq-elts re)) tail))
	      ((rxt-trivial-p re) tail)	; Drop trivial elts
	      ((and (rxt-string-p re)	; Flatten strings
		    (consp tail)
		    (rxt-string-p (car tail)))
	       (cons
		(rxt-string
		 (concat (rxt-string-chars re)
			 (rxt-string-chars (car tail))))
		(cdr tail)))
	      (t (cons re tail))))
    '()))

;;; Choice
(defstruct
  (rxt-choice
   (:constructor make-rxt-choice (elts)))
  elts)

;; The empty choice (always fails)
(defvar rxt-empty (make-rxt-choice nil))
(defun rxt-empty-p (re)
  (or
   (and (rxt-choice-p re)
        (null (rxt-choice-elts re)))
   (rxt-empty-char-set-p re)))
  
;; Slightly smart choice constructor:
;; -- flattens nested choices
;; -- drops never-matching (empty) REs
;; -- folds character sets and single-char strings together
;; -- singleton choice reduced to the element itself
(defun rxt-choice (res)
  (let ((res (rxt-choice-flatten res)))
    (if (consp res)
	(if (consp (cdr res))
	    (make-rxt-choice res)	; General case
	  (car res))                    ; Singleton choice
      rxt-empty)))

;; Flatten any nested rxt-choices amongst RES, and collect any
;; charsets together
(defun rxt-choice-flatten (res)
  (multiple-value-bind (res cset)
      (rxt-choice-flatten+char-set res)
    (if (not (rxt-empty-p cset))
        (cons cset res)
      res)))

;; Does the real work for the above. Returns two values: a flat list
;; of elements (with any rxt-choices reduced to their contents), and a
;; char-set union that collects together all the charsets and
;; single-char strings
(defun rxt-choice-flatten+char-set (res)
  (if (null res)
      (values '() (make-rxt-char-set))
    (let* ((re (car res)))
      (multiple-value-bind (tail cset)
          (rxt-choice-flatten+char-set (cdr res))
	(cond ((rxt-choice-p re)        ; Flatten nested choices
	       (values
                (append (rxt-choice-elts re) tail)
                cset))

	      ((rxt-empty-p re)         ; Drop empty re's.
               (values tail cset))

              ((rxt-char-set-p re)      ; Fold char sets together
               (values tail
                       (rxt-char-set-adjoin! cset re)))

              ((and (rxt-string-p re)   ; Same for 1-char strings
                    (= 1 (length (rxt-string-chars re))))
               (values tail
                       (rxt-char-set-adjoin! cset
                                             (rxt-string-chars re))))

	      (t                        ; Otherwise.
               (values (cons re tail) cset)))))))

;;; Repetition
(defstruct rxt-repeat
  from to body greedy)

(defun* rxt-repeat (from to body &optional (greedy t))
  (if (equal to 0)
      rxt-empty-string
    (make-rxt-repeat :from from :to to
                     :body body :greedy greedy)))

;;; Submatch
(defstruct
  (rxt-submatch
   (:constructor rxt-submatch (body)))
  body)

;;; Backreference (not in SRE)
(defstruct
  (rxt-backref
   (:constructor rxt-backref (n)))
  n)

;;; Syntax classes (Emacs only)
(defstruct rxt-syntax-class
  symbol)

(defun rxt-syntax-class (symbol)
  (if (assoc symbol rx-syntax)
      (make-rxt-syntax-class :symbol symbol)
    (error "Invalid syntax class symbol %s" symbol)))

;;; Character categories (Emacs only)
(defstruct rxt-char-category
  symbol)

(defun rxt-char-category (symbol)
  (if (assoc symbol rx-categories)
      (make-rxt-char-category :symbol symbol)
    (error "Invalid character category symbol %s" symbol)))


;;; Char sets
;; char set ::= <re-char-set> 
;;            | <re-char-set-negation>
;;            | <re-choice> ; where all rxt-choice-elts are char sets
;;            | <re-char-set-intersection>

;; An rxt-char-set represents the union of any number of characters,
;; character ranges, and POSIX character classes: anything that can be
;; represented in string notation as a class [ ... ] without the
;; negation operator.
(defstruct rxt-char-set
  chars					; list of single characters
  ranges				; list of ranges (from . to)
  classes)				; list of character classes

(defun rxt-char-set (item)
  "Construct an abstract regexp character set from ITEM.

ITEM may be a single character, a string or list of characters, a
range represented as a cons (FROM . TO), a symbol representing a
POSIX class, or an existing character set, which is returned
unchanged."
  (cond
   ((rxt-cset-p item) item)

   ((integerp item)
    (make-rxt-char-set :chars (list item)))

   ((consp item)
    (if (consp (cdr item))              
	(make-rxt-char-set :chars item)         ; list of chars
      (make-rxt-char-set :ranges (list item)))) ; range (from . to)

   ((stringp item)
    (make-rxt-char-set :chars (mapcar 'identity item)))

   ((symbolp item)
    (make-rxt-char-set :classes (list item)))

   (t
    (error "Attempt to make char-set out of %S" item))))

;; Destructive char-set union 
(defun rxt-char-set-adjoin! (cset item)
  "Destructively add the contents of ITEM to character set CSET.

CSET must be an rxt-char-set. ITEM may be an rxt-char-set, or any
of these shortcut representations: a single character which
stands for itself, a cons (FROM . TO) representing a range, or a
symbol naming a posix class: 'digit, 'alnum, etc.

Returns the union of CSET and ITEM; CSET may be destructively
modified."
  (assert (rxt-char-set-p cset))

  (cond
   ((integerp item)			; character
    (push item (rxt-char-set-chars cset)))

   ((consp item)
    (if (consp (cdr item))
        (dolist (char item)             ; list of chars
          (rxt-char-set-adjoin! cset char))
      (push item (rxt-char-set-ranges cset)))) ; range (from . to)

   ((stringp item) 
    (mapc (lambda (char)
            (rxt-char-set-adjoin! cset char))
          item))

   ((symbolp item)			; posix character class
    (push item (rxt-char-set-classes cset)))

   ((rxt-char-set-p item)
    (dolist (type (list (rxt-char-set-chars item)
                        (rxt-char-set-ranges item)
                        (rxt-char-set-classes item)))
      (dolist (thing type)
        (rxt-char-set-adjoin! cset thing))))

   (t
    (error "Can't adjoin non-rxt-char-set, character, range or symbol %S" item)))
  cset)

(defun rxt-empty-char-set-p (cset)
  (and (rxt-char-set-p cset)
       (null (rxt-char-set-chars cset))
       (null (rxt-char-set-ranges cset))
       (null (rxt-char-set-classes cset))))

;;; Set complement of character set, syntax class, or character
;;; category

;; In general, all character sets that can be represented in string
;; notation as [^ ... ] (but see `rxt-intersection', below), plus
;; Emacs' \Sx and \Cx constructions. 
(defstruct rxt-char-set-negation
  elt)

;; Complement constructor: checks types, unwraps existing negations
(defun rxt-negate (cset)
  "Return the logical complement (negation) of CSET.

CSET may be one of the following types: `rxt-char-set',
`rxt-syntax-class', `rxt-char-category', `rxt-char-set-negation';
or a shorthand char-set specifier (see `rxt-char-set')`."
  (cond ((or (rxt-char-set-p cset)
	     (rxt-syntax-class-p cset)
             (rxt-char-category-p cset))
	 (make-rxt-char-set-negation :elt cset))

	((or (integerp cset) (consp cset) (symbolp cset) (stringp cset))
	 (make-rxt-char-set-negation
	  :elt (rxt-char-set cset)))

	((rxt-char-set-negation-p cset)
	 (rxt-char-set-negation-elt cset))

	(t
	 (error "Can't negate non-char-set or syntax class %s" cset))))
  
;;; Intersections of char sets

;; These are difficult to represent in general, but can be constructed
;; in Perl using double negation; for example: [^\Wabc] means the set
;; complement of [abc] with respect to the universe of "word
;; characters": (& (~ (~ word)) (~ ("abc"))) == (& word (~ ("abc")))
;; == (- word ("abc"))

(defstruct rxt-intersection
  elts)

(defun rxt-intersection (charsets)
  (let ((elts '())
	(cmpl (make-rxt-char-set)))
    (dolist (cset (rxt-int-flatten charsets))
      (cond
       ((rxt-char-set-negation-p cset)
	;; Fold negated charsets together: ~A & ~B = ~(A|B)
	(setq cmpl (rxt-char-set-adjoin! cmpl (rxt-char-set-negation-elt cset))))
       
       ((rxt-char-set-p cset)
	(push cset elts))

       (t
	(error "Can't take intersection of non-character-set %s" cset))))
    (if (null elts)
	(rxt-negate cmpl)
      (unless (rxt-empty-char-set-p cmpl)
	(push (rxt-negate cmpl) elts))
      (if (null (cdr elts))
	  (car elts)			; singleton case
	(make-rxt-intersection :elts elts)))))
	
;; Constructor helper: flatten nested intersections
(defun rxt-int-flatten (csets)
  (if (consp csets)
      (let ((cset (car csets))
	    (tail (rxt-int-flatten (cdr csets))))
	(if (rxt-intersection-p cset)
	    (append (rxt-int-flatten (rxt-intersection-elts cset)) tail)
	  (cons cset tail)))
    '()))
	  
;;; Higher-level character set combinations: intersection and union
;; Here a cset may be an `rxt-char-set', `rxt-char-set-negation',
;; `rxt-intersection', or `rxt-choice' whose elements are all csets
(defun rxt-cset-p (cset)
  (or (rxt-char-set-p cset)
      (rxt-char-set-negation-p cset)
      (rxt-intersection-p cset)
      (and (rxt-choice-p cset)
	   (every #'rxt-cset-p (rxt-choice-elts cset)))))

(defun rxt-cset-union (csets)
  (let ((union (make-rxt-char-set))) 
    (dolist (cset csets)
      (if (rxt-choice-p union)
	  (setq union (rxt-choice (list union cset)))
	;; else, `union' is a char-set
	(cond
	 ((rxt-char-set-p cset)
	  (setq union (rxt-char-set-adjoin! union cset)))

	 ((rxt-char-set-negation-p cset)
	  (setq union (rxt-choice (list union cset))))

	 ((rxt-intersection-p cset)
	  (setq union (rxt-choice (list union cset))))

	 ((rxt-choice-p cset)
	  (setq union (rxt-choice (list union cset))))

	 (t
	  (error "Non-cset %S in rxt-cset-union" cset)))))
    union))

(defun rxt-cset-intersection (csets)
  (rxt-intersection csets))



;;;; ADT unparsers to rx and sre notation

;;; ADT -> rx notation
(defun rxt-adt->rx (re)
  (cond
   ((rxt-primitive-p re)
    (rxt-primitive-rx re))

   ((rxt-string-p re) (rxt-string-chars re))

   ((rxt-seq-p re)
    (cons 'seq (mapcar #'rxt-adt->rx (rxt-seq-elts re))))

   ((rxt-choice-p re)
    (cons 'or (mapcar #'rxt-adt->rx (rxt-choice-elts re))))

   ((rxt-submatch-p re)
    (if (rxt-seq-p (rxt-submatch-body re))
	(cons 'submatch
	      (mapcar #'rxt-adt->rx (rxt-seq-elts (rxt-submatch-body re))))
      (list 'submatch (rxt-adt->rx (rxt-submatch-body re)))))

   ((rxt-backref-p re)
    (let ((n (rxt-backref-n re)))
      (if (<= n 9)
          (list 'backref (rxt-backref-n re))
        (error "Too many backreferences (%s)" n))))

   ((rxt-syntax-class-p re)
    (list 'syntax (rxt-syntax-class-symbol re)))

   ((rxt-char-category-p re)
    (list 'category (rxt-char-category-symbol re)))

   ((rxt-repeat-p re)
    (let ((from (rxt-repeat-from re))
	  (to (rxt-repeat-to re))
          (greedy (rxt-repeat-greedy re))
	  (body (rxt-adt->rx (rxt-repeat-body re))))
      (cond
       ((and (zerop from) (null to))
        (list (if greedy '* '*?) body))
       ((and (equal from 1) (null to))
        (list (if greedy '+ '+?) body))
       ((and (zerop from) (equal to 1))
        (list (if greedy 'opt '\??) body))
       ((null to) (list '>= from body))
       ((equal from to)
	(list '= from body))
       (t
	(list '** from to body)))))

   ((rxt-char-set-p re)
    (if (and (null (rxt-char-set-chars re))
	     (null (rxt-char-set-ranges re))
	     (= 1 (length (rxt-char-set-classes re))))
	(car (rxt-char-set-classes re))
      (append
       '(any)
       (and (rxt-char-set-chars re)
	    (mapcar 'char-to-string (rxt-char-set-chars re)))

       (mapcar
	(lambda (range)
	  (format "%c-%c" (car range) (cdr range)))
	(rxt-char-set-ranges re))

       (rxt-char-set-classes re))))

   ((rxt-char-set-negation-p re)
    (list 'not (rxt-adt->rx (rxt-char-set-negation-elt re))))

   (t
    (error "No RX translation for %s" re))))

;;; ADT -> SRE notation
(defun rxt-adt->sre (re)
  (cond
   ((rxt-primitive-p re)
    (rxt-primitive-sre re))

   ((rxt-string-p re) (rxt-string-chars re))

   ((rxt-seq-p re)
    (cons ': (mapcar #'rxt-adt->sre (rxt-seq-elts re))))

   ((rxt-choice-p re)
    (cons '| (mapcar #'rxt-adt->sre (rxt-choice-elts re))))

   ((rxt-submatch-p re)
    (if (rxt-seq-p (rxt-submatch-body re))
	(cons 'submatch
	      (mapcar #'rxt-adt->sre (rxt-seq-elts (rxt-submatch-body re))))
      (list 'submatch (rxt-adt->sre (rxt-submatch-body re)))))

   ((rxt-repeat-p re)
    (let ((from (rxt-repeat-from re))
	  (to (rxt-repeat-to re))
          (greedy (rxt-repeat-greedy re))
	  (body (rxt-adt->sre (rxt-repeat-body re))))
      (when (not greedy)
        (error "No SRE translation of non-greedy repetition %s" re))
      (cond
       ((and (zerop from) (null to)) (list '* body))
       ((and (equal from 1) (null to)) (list '+ body))
       ((and (zerop from) (equal to 1)) (list '\? body))
       ((null to) (list '>= from body))
       ((equal from to)
	(list '= from body))
       (t
	(list '** from to body)))))

   ((rxt-char-set-p re)
    (let* ((chars (mapconcat 'char-to-string (rxt-char-set-chars re) ""))

	   (ranges
	    (mapcar
	     (lambda (range)
	       (format "%c%c" (car range) (cdr range)))
	     (rxt-char-set-ranges re)))

	   (classes (rxt-char-set-classes re))

	   (all
	    (append
	     (if (not (zerop (length chars))) `((,chars)) nil)
	     (if ranges `((/ ,@ranges)) nil)
	     classes)))
      (if (> (length all) 1)
	  (cons '| all)
	(car all))))
      
   ((rxt-char-set-negation-p re)
    (list '~ (rxt-adt->sre (rxt-char-set-negation-elt re))))

   ((rxt-intersection-p re)
    (cons '& (mapcar #'rxt-adt->sre (rxt-intersection-elts re))))

   (t
    (error "No SRE translation for %s" re))))



;;;; ADT unparser to PCRE notation
;;; Based on scsh/posixstr.scm in scsh

;; To ensure that the operator precedence in the generated regexp does
;; what we want, we need to keep track of what kind of production is
;; returned from each step. Therefore these functions return a string
;; and a numeric "level" which lets the function using the generated
;; regexp know whether it has to be parenthesized:
;;
;; 0: an already parenthesized expression
;;
;; 1: a "piece" binds to any succeeding quantifiers
;;
;; 2: a "branch", or concatenation of pieces, needs parenthesizing to
;; bind to quantifiers
;;
;; 3: a "top", or alternation of branches, needs parenthesizing to
;; bind to quantifiers or to concatenation
;;
;; This idea is stolen straight out of the scsh implementation.

(defun rxt-adt->pcre (re)
  (multiple-value-bind (s lev) (rxt-adt->pcre/lev re) s))

(defun rxt-adt->pcre/lev (re)
  (cond
   ((rxt-primitive-p re)
    (let ((s (rxt-primitive-pcre re)))
      (if s
	  (values s 1)
	(error "No PCRE translation for %s" re))))

   ((rxt-string-p re) (rxt-string->pcre re))
   ((rxt-seq-p re) (rxt-seq->pcre re))
   ((rxt-choice-p re) (rxt-choice->pcre re))

   ((rxt-submatch-p re) (rxt-submatch->pcre re))
   ((rxt-backref-p re)
    (values (format "\\%d" (rxt-backref-n re)) 1))
 
   ((rxt-repeat-p re) (rxt-repeat->pcre re))

   ((or (rxt-char-set-p re)
	(rxt-char-set-negation-p re))
    (rxt-char-set->pcre re))

   ;; ((rxt-intersection re) (rxt-char-set-intersection->pcre re))

   (t
    (error "No PCRE translation for %s" re))))

(defvar rxt-pcre-metachars (rx (any "\\^.$|()[]*+?{}")))
(defvar rxt-pcre-charset-metachars (rx (any "]" "[" "\\" "^" "-")))

(defun rxt-string->pcre (re)
  (values
   (replace-regexp-in-string
    rxt-pcre-metachars
    "\\\\\\&" (rxt-string-chars re))
   ;; One-char strings are pieces (bind to quantifiers), longer are
   ;; branches (need parenthesizing to be quantified)
   (if (> (length re) 1) 1 2)))

(defun rxt-seq->pcre (re)
  (let ((elts (rxt-seq-elts re)))
    (if (null elts)
	""
      (rxt-seq-elts->pcre elts))))

(defun rxt-seq-elts->pcre (elts)
  (multiple-value-bind
      (s lev) (rxt-adt->pcre/lev (car elts))
    (if (null (cdr elts))
	(values s lev)
      (multiple-value-bind
	  (s1 lev1) (rxt-seq-elts->pcre (cdr elts))
	(values (concat (rxt-paren-if-necessary s lev)
			(rxt-paren-if-necessary s1 lev1))
		2)))))

(defun rxt-paren-if-necessary (s lev)
  (if (< lev 3)
      s
      (concat "(?:" s ")")))

(defun rxt-choice->pcre (re)
  (let ((elts (rxt-choice-elts re)))
    (if (null elts)
	nil
      (rxt-choice-elts->pcre elts))))
	
(defun rxt-choice-elts->pcre (elts)
  (multiple-value-bind
      (s lev) (rxt-adt->pcre/lev (car elts))
    (if (null (cdr elts))
	(values s lev)
      (multiple-value-bind
	  (s1 lev1) (rxt-choice-elts->pcre (cdr elts))
	(values (concat s "|" s1) 3)))))

(defun rxt-submatch->pcre (re)
  (multiple-value-bind
      (s lev) (rxt-adt->pcre/lev (rxt-submatch-body re))
    (values (concat "(" s ")") 0)))

(defun rxt-repeat->pcre (re)
  (let ((from (rxt-repeat-from re))
	(to (rxt-repeat-to re))
	(body (rxt-repeat-body re))
        (greedy (rxt-repeat-greedy re)))
    (multiple-value-bind
	(s lev) (rxt-adt->pcre/lev body)
      (cond
       ((and to (= from 1) (= to 1)) (values s lev))
       ((and to (= from 0) (= to 0)) (values "" 2))
       (t
	(when (> lev 1)			; parenthesize non-atoms
	  (setq s (concat "(?:" s ")")
		lev 0))
	(values (if to
		    (cond ((and (= from 0) (= to 1))
                           (concat s (if greedy "?" "??")))
			  ((= from to)
			   (concat s "{" (number-to-string to) "}"))
			  (t
			   (concat s "{" (number-to-string from)
					  "," (number-to-string to) "}")))
		  (cond ((= from 0)
                         (concat s (if greedy "*" "*?")))
			((= from 1)
                         (concat s (if greedy "+" "+?")))
			(t (concat s "{" (number-to-string from) ",}"))))
		1))))))
	
(defun rxt-char-set->pcre (re)
  (cond ((rxt-char-set-p re)
	 (values
	  (concat "[" (rxt-char-set->pcre/chars re) "]") 1))

	((rxt-char-set-negation-p re)
	 (let ((elt (rxt-char-set-negation-elt re)))
	   (if (rxt-char-set-p elt)
	       (values
		(concat "[^" (rxt-char-set->pcre/chars elt) "]") 1)
	     (error "No PCRE translation of %s" elt))))

	(t
	 (error "Non-char-set in rxt-char-set->pcre: %s" re))))
	 
;; Fortunately, easier in PCRE than in POSIX!
(defun rxt-char-set->pcre/chars (re)
  (flet
      ((escape
	(char)
	(let ((s (char-to-string char)))
	  (cond ((string-match rxt-pcre-charset-metachars s)
		 (concat "\\" s))

		((and (not (string= s " "))
		      (string-match "[^[:graph:]]" s))
		 (format "\\x{%x}" char))

		(t s)))))

    (let ((chars (rxt-char-set-chars re))
	  (ranges (rxt-char-set-ranges re))
	  (classes (rxt-char-set-classes re)))

      (concat
       (mapconcat #'escape chars "")
       (mapconcat #'(lambda (rg)
		      (format "%s-%s"
			      (escape (car rg))
			      (escape (cdr rg))))
		  ranges "")
       (mapconcat #'(lambda (class)
		      (format "[:%s:]" class))
		  classes "")))))


;;;; Generate all productions of a finite regexp

(defun rxt-adt->strings (re)
  (cond
   ((rxt-primitive-p re) (list ""))

   ((rxt-string-p re) (list (rxt-string-chars re)))
   ((rxt-seq-p re) (rxt-seq-elts->strings (rxt-seq-elts re)))
   ((rxt-choice-p re) (rxt-choice-elts->strings (rxt-choice-elts re)))

   ((rxt-submatch-p re) (rxt-adt->strings (rxt-submatch-body re)))

   ((rxt-repeat-p re) (rxt-repeat->strings re))

   ((rxt-char-set-p re) (rxt-char-set->strings re))

   (t
    (error "Can't generate matches for %s" re))))

(defun rxt-concat-product (heads tails)
  (mapcan
   (lambda (hs)
     (mapcar
      (lambda (ts) (concat hs ts))
      tails))
   heads))

(defun rxt-seq-elts->strings (elts)
  (if (null elts)
      '("")
    (let ((heads (rxt-adt->strings (car elts)))
	  (tails (rxt-seq-elts->strings (cdr elts))))
      (rxt-concat-product heads tails))))

(defun rxt-choice-elts->strings (elts)
  (if (null elts)
      '()
    (append (rxt-adt->strings (car elts))
	    (rxt-choice-elts->strings (cdr elts)))))

(defun rxt-repeat->strings (re)
  (let ((from (rxt-repeat-from re))
	(to (rxt-repeat-to re)))
    (if (not to)
	(error "Can't generate matches for unbounded repeat %s"
	re)
      (let ((strings (rxt-adt->strings (rxt-repeat-body re))))
	(rxt-repeat-n-m->strings from to strings)))))

(defun rxt-repeat-n-m->strings (from to strings)
  (cond
   ((zerop to) '(""))
   ((= to from) (rxt-repeat-n->strings from strings))
   (t 					; to > from
    (let* ((strs-n (rxt-repeat-n->strings from strings))
	   (accum (copy-list strs-n)))
      (dotimes (i (- to from))
	(setq strs-n (rxt-concat-product strs-n strings))
	(setq accum (nconc accum strs-n)))
      accum))))
	      
(defun rxt-repeat-n->strings (n strings)
  ;; n > 1
  (cond ((zerop n) '(""))
	((= n 1) strings)
	(t
	 (rxt-concat-product
	  (rxt-repeat-n->strings (- n 1) strings)
	  strings))))

(defun rxt-char-set->strings (re)
  (if (rxt-char-set-classes re)
      (error "Can't generate matches for character classes")
    (let ((chars (mapcar #'char-to-string (rxt-char-set-chars re))))
      (dolist (range (rxt-char-set-ranges re))
	(let ((end (cdr range)))
	  (do ((i (car range) (+ i 1)))
	      ((> i end))
	    (push (char-to-string i) chars))))
      chars)))
	
  


;;;; String regexp -> ADT parser

(defvar rxt-parse-pcre nil
  "t if the rxt string parser is parsing PCRE syntax, nil for Elisp syntax.

This should only be let-bound by `rxt-parse-re', never set otherwise.")

(defvar rxt-pcre-extended-mode nil
  "t if the rxt string parser is emulating PCRE's \"extended\" mode.

In extended mode (indicated by /x in Perl/PCRE), whitespace
outside of character classes and \\Q...\\E quoting is ignored,
and a `#' character introduces a comment that extends to the end
of line.")

(defvar rxt-pcre-s-mode nil
  "t if the rxt string parser is emulating PCRE's single-line \"/s\" mode.

When /s is used, PCRE's \".\" matches newline characters, which
otherwise it would not match.")

(defun rxt-parse-exp ()
  (let ((rxt-pcre-extended-mode rxt-pcre-extended-mode)
        (rxt-pcre-s-mode rxt-pcre-s-mode)
        (bar (regexp-quote (if rxt-parse-pcre "|" "\\|"))))
    (if (not (eobp))
	(let ((branches '()))
	  (catch 'done
	    (while t
	      (let ((branch (rxt-parse-branch)))
		(setq branches (cons branch branches))
                (rxt-extended-skip)
		(if (looking-at bar)
		    (goto-char (match-end 0))
		  (throw 'done (rxt-choice (reverse branches))))))))
      (rxt-choice nil))))

(defun rxt-extended-skip ()
  "Skip over whitespace and comments in PCRE extended regexps."
  (when rxt-pcre-extended-mode
    (skip-syntax-forward "-")
    (while (looking-at "#")
      (beginning-of-line 2)
      (skip-syntax-forward "-"))))

(defun rxt-parse-branch ()
  (let ((stop
	 (regexp-opt
	  (if rxt-parse-pcre '("|" ")") '("\\|" "\\)")))))
    (rxt-extended-skip)
    (if (or (eobp)
            (looking-at stop))
        rxt-empty-string
      (let ((pieces (list (rxt-parse-piece t))))
        (while (not (or (eobp)
                        (looking-at stop)))
          (let ((piece (rxt-parse-piece nil)))
            (push piece pieces)))
        (rxt-seq (reverse pieces))))))

;; Parse a regexp "piece": an atom (`rxt-parse-atom') plus any
;; following quantifiers
(defun rxt-parse-piece (&optional branch-begin)
  (rxt-extended-skip)
  (let ((atom (rxt-parse-atom branch-begin)))
    (rxt-parse-quantifiers atom)))

;; Parse any and all quantifiers after ATOM and return the quantified
;; regexp, or ATOM unchanged if no quantifiers
(defun rxt-parse-quantifiers (atom)
  (catch 'done
    (while (not (eobp))
      (let ((atom1 (rxt-parse-quantifier atom)))
        (if (eq atom1 atom)
            (throw 'done t)
          (setq atom atom1)))))
  atom)

;; Possibly parse a single quantifier after ATOM and return the
;; quantified atom, or ATOM if no quantifier
(defun rxt-parse-quantifier (atom)
  (rxt-extended-skip)
  (rxt-token-case
   ((rx "*?") (rxt-repeat 0 nil atom nil))
   ((rx "*") (rxt-repeat 0 nil atom t))

   ((rx "+?") (rxt-repeat 1 nil atom nil))
   ((rx "+") (rxt-repeat 1 nil atom t))

   ((rx "??") (rxt-repeat 0 1 atom nil))
   ((rx "?") (rxt-repeat 0 1 atom t))

   ((if rxt-parse-pcre "{" "\\\\{")
    (multiple-value-bind (from to)
	(rxt-parse-braces)
      (rxt-repeat from to atom)))

   (t atom)))

;; Parse a regexp atom, i.e. an element that binds to any following
;; quantifiers. This includes characters, character classes,
;; parenthesized groups, assertions, etc.
(defun rxt-parse-atom (&optional branch-begin)
  (if (eobp)
      (error "Unexpected end of regular expression")
    (if rxt-parse-pcre
	(rxt-parse-atom/pcre)
      (rxt-parse-atom/el branch-begin))))

(defun rxt-parse-atom/common ()
  (rxt-token-case 
   ("\\[" (rxt-parse-char-class))
   ("\\\\b" rxt-word-boundary)
   ("\\\\B" rxt-not-word-boundary)))

(defun rxt-parse-atom/el (branch-begin)
  (or (rxt-parse-atom/common)
      (rxt-token-case
       ("\\." rxt-nonl)

       ;; "^" and "$" are metacharacters only at beginning or end of a
       ;; branch in Elisp; elsewhere they are literals
       ("\\^" (if branch-begin
                  rxt-bol
                (rxt-string "^")))
       ("\\$" (if (or (eobp)
                      (looking-at (rx (or "\\)" "\\|"))))
                  rxt-eol
                (rxt-string "$")))

       ("\\\\(" (rxt-parse-subgroup/el)) ; Subgroup
   
       ("\\\\w" rxt-wordchar)
       ("\\\\W" rxt-not-wordchar)

       ("\\\\`" rxt-bos)
       ("\\\\'" rxt-eos)
       ("\\\\<" rxt-bow)
       ("\\\\>" rxt-eow)
       ("\\\\_<" rxt-symbol-start)
       ("\\\\_>" rxt-symbol-end)

       ;; Syntax categories
       ((rx "\\"
            (submatch (any "Ss"))
            (submatch (any "-.w_()'\"$\\/<>|!")))
	(let ((negated (string= (match-string 1) "S"))
	      (re
	       (rxt-syntax-class
		(car (rassoc (string-to-char (match-string 2))
			     rx-syntax)))))
	  (if negated (rxt-negate re) re)))

       ;; Character categories
       ((rx "\\"
            (submatch (any "Cc"))
            (submatch nonl))
        (let ((negated (string= (match-string 1) "C"))
              (category
               (car (rassoc (string-to-char (match-string 2))
                            rx-categories))))
          (unless category
            (error "Unrecognized character category %s" (match-string 2)))
          (let ((re (rxt-char-category category)))
            (if negated (rxt-negate re) re))))

       ("\\\\\\([1-9]\\)"			; Backreference
	(rxt-backref (string-to-number (match-string 1))))

       ;; Any other escaped character
       ("\\\\\\(.\\)" (rxt-string (match-string 1)))

       ;; Everything else
       (".\\|\n" (rxt-string (match-string 0))))))

(defvar rxt-subgroup-count nil)

(defvar rxt-pcre-word-chars
  (make-rxt-char-set :chars '(?_)
                     :classes '(alnum)))

(defvar rxt-pcre-non-word-chars
  (rxt-negate rxt-pcre-word-chars))

(defun rxt-parse-atom/pcre ()
  (rxt-extended-skip)
  (or (rxt-parse-atom/common)

      (let ((char (rxt-parse-escapes/pcre)))
	(and char
	     (rxt-string (char-to-string char))))

      (rxt-token-case
       ("\\."
        (if rxt-pcre-s-mode
            rxt-anything
          rxt-nonl))

       ("\\^" rxt-bol)
       ("\\$" rxt-eol)

       ("(" (rxt-parse-subgroup/pcre)) ; Subgroup
       
       ("\\\\A" rxt-bos)
       ("\\\\Z" rxt-eos)

       ("\\\\w" rxt-pcre-word-chars)
       ("\\\\W" rxt-pcre-non-word-chars)

       ("\\\\Q"				; begin regexp quoting
        ;; It would seem simple to take all the characters between \Q
        ;; and \E and make an rxt-string, but \Q...\E isn't an atom:
        ;; any quantifiers afterward should bind only to the last
        ;; character, not the whole string.
	(let ((begin (point)))
	  (search-forward "\\E" nil t)
          (let* ((end (match-beginning 0))
                 (str (buffer-substring-no-properties begin (1- end)))
                 (char (char-to-string (char-before end))))
            (rxt-seq (list (rxt-string str)
                           (rxt-parse-quantifiers (rxt-string char)))))))
       
       ;; Various character classes
       ("\\\\d" (rxt-char-set 'digit))
       ("\\\\D" (rxt-negate 'digit))
       ("\\\\h" (rxt-char-set pcre-horizontal-whitespace-chars))
       ("\\\\H" (rxt-negate pcre-horizontal-whitespace-chars))
       ("\\\\s" (rxt-char-set 'space))
       ("\\\\S" (rxt-negate 'space))
       ("\\\\v" (rxt-char-set pcre-vertical-whitespace-chars))
       ("\\\\V" (rxt-negate pcre-vertical-whitespace-chars))

       ("\\\\\\([0-9]+\\)"		; backreference or octal char?
	(let* ((digits (match-string 1))
	       (dec (string-to-number digits)))
	  ;; from "man pcrepattern": If the number is less than 10, or if
	  ;; there have been at least that many previous capturing left
	  ;; parentheses in the expression, the entire sequence is taken
	  ;; as a back reference.
	  (if (and (> dec 0)
                   (or (< dec 10)
                       (>= rxt-subgroup-count dec)))
	      (rxt-backref dec)
	
	    ;; from "man pcrepattern": if the decimal number is greater
	    ;; than 9 and there have not been that many capturing
	    ;; subpatterns, PCRE re-reads up to three octal digits
	    ;; following the backslash, and uses them to generate a data
	    ;; character. Any subsequent digits stand for themselves.
	    (goto-char (match-beginning 1))
	    (re-search-forward "[0-7]\\{0,3\\}")
	    (rxt-string (char-to-string (string-to-number (match-string 0) 8))))))

       ;; Any other escaped character
       ("\\\\\\(.\\)" (rxt-string (match-string 1)))

       ;; Everything else
       (".\\|\n" (rxt-string (match-string 0))))))

(defun rxt-parse-escapes/pcre ()
  "Consume a one-char PCRE escape at point and return its codepoint equivalent.

Handles only those character escapes which have the same meaning
in character classes as outside them."
  (rxt-token-case
   ("\\\\a" #x07)  ; bell
   ("\\\\c\\(.\\)"                  ; control character
    ;; from `man pcrepattern':
    ;; The precise effect of \cx is as follows: if x is a lower case
    ;; letter, it is converted to upper case.  Then bit 6 of the
    ;; character (hex 40) is inverted.
    (logxor (string-to-char (upcase (match-string 1))) #x40))
   ("\\\\e" #x1b)  ; escape
   ("\\\\f" #x0c)  ; formfeed
   ("\\\\n" #x0a)  ; linefeed
   ("\\\\r" #x0d)  ; carriage return
   ("\\\\t" #x09)  ; tab
   
   ("\\\\x\\([A-Za-z0-9]\\{1,2\\}\\)"
    (string-to-number (match-string 1) 16))
   ("\\\\x{\\([A-Za-z0-9]*\\)}"
    (string-to-number (match-string 1) 16))))

(defun rxt-extended-flag (flags)
  (if (string-match-p "x" flags) t nil))

(defun rxt-s-flag (flags)
  (if (string-match-p "s" flags) t nil))

(defun rxt-parse-subgroup/pcre ()
  (catch 'return 
    (let ((shy nil)
          (x rxt-pcre-extended-mode)
          (s rxt-pcre-s-mode))
      (rxt-extended-skip)
      ;; Check for special constructs (? ... ) and (* ...)
      (rxt-token-case
       ((rx "?")                        ; (? ... )
        (rxt-token-case
         (":" (setq shy t))             ; Shy group (?: ...)
         ("#"                           ; Comment (?# ...)
          (search-forward ")")
          (throw 'return rxt-trivial))
         ((rx (or                       ; Set/unset s & x modifiers
               (seq (group (* (any "xs"))) "-" (group (+ (any "xs"))))
               (seq (group (+ (any "xs"))))))
          (let ((begin (match-beginning 0))
                (on (or (match-string 1) (match-string 3)))
                (off (or (match-string 2) "")))
            (if (rxt-extended-flag on) (setq x t))
            (if (rxt-s-flag on) (setq s t))
            (if (rxt-extended-flag off) (setq x nil))
            (if (rxt-s-flag off) (setq s nil))
            (rxt-token-case
             (":" (setq shy t))   ; Parse a shy group with these flags
             (")"
              ;; Set modifiers here to take effect for the remainder
              ;; of this expression; they are let-bound in
              ;; rxt-parse-exp
              (setq rxt-pcre-extended-mode x
                    rxt-pcre-s-mode s)
              (throw 'return rxt-trivial))
             (t
              (error "Unrecognized PCRE extended construction (?%s...)"
                     (buffer-substring-no-properties begin (point)))))))
         (t (error "Unrecognized PCRE extended construction ?%c"
                   (char-after)))))

       ((rx "*")                ; None of these are recognized: (* ..)
        (let ((begin (point)))
          (search-forward ")")
          (error "Unrecognized PCRE extended construction (*%s"
                 (buffer-substring begin (point))))))

      ;; Parse the remainder of the subgroup
      (unless shy (incf rxt-subgroup-count))
      (let* ((rxt-pcre-extended-mode x)
             (rxt-pcre-s-mode s)
             (rx (rxt-parse-exp)))
        (rxt-extended-skip)
        (rxt-token-case
         (")" (if shy rx (rxt-submatch rx)))
         (t (error "Subexpression missing close paren")))))))

(defun rxt-parse-subgroup/el ()
  (let ((shy (rxt-token-case ("\\?:" t))))
    (unless shy (incf rxt-subgroup-count))
    (let ((rx (rxt-parse-exp)))
      (rxt-token-case
       ((rx "\\)") (if shy rx (rxt-submatch rx)))
       (t (error "Subexpression missing close paren"))))))

(defun rxt-parse-braces ()
  (rxt-token-case
   ((if rxt-parse-pcre
	"\\([0-9]*\\),\\([0-9]+\\)}"
      "\\([0-9]*\\),\\([0-9]+\\)\\\\}")
    (values (string-to-number (match-string 1))
	    (string-to-number (match-string 2))))
   ((if rxt-parse-pcre "\\([0-9]+\\),}" "\\([0-9]+\\),\\\\}")
    (values (string-to-number (match-string 1)) nil))
   ((if rxt-parse-pcre "\\([0-9]+\\)}" "\\([0-9]+\\)\\\\}")
    (let ((a (string-to-number (match-string 1))))
      (values a a)))
   (t
    (let ((begin (point)))
      (search-forward "}" nil 'go-to-end)
      (error "Bad brace expression {%s"
             (buffer-substring-no-properties begin (point)))))))

;; Parse a character set range [...]		 
(defvar rxt-posix-classes
  (rx "[:"
      (submatch
       (or "alnum" "alpha" "ascii" "blank" "cntrl" "digit" "graph" "lower"
           "print" "punct" "space" "upper" "word" "xdigit"))
      ":]"))

(defun rxt-parse-char-class ()
 (when (eobp)
   (error "Missing close right bracket in regexp"))

  (let* ((negated (rxt-token-case
		   ("\\^" t)
		   (t nil)))
	 (begin (point))
	 (result (if negated
		     (rxt-negate (make-rxt-char-set))
		   (make-rxt-char-set)))
	 (builder (if negated
		      #'rxt-cset-intersection
		    #'rxt-cset-union)))
    (catch 'done
      (while t
	(when (eobp)
	  (error "Missing close right bracket in regexp"))
	
	(if (and (looking-at "\\]")
		 (not (= (point) begin)))
	    (throw 'done result)
	  (let* ((piece (rxt-parse-char-class-piece))
		 (cset
		  (if negated
		      (rxt-negate (rxt-char-set piece))
		    (rxt-char-set piece))))
	    (setq result
		  (funcall builder (list result cset)))))))
    ;; Skip over closing "]"
    (forward-char)
    result))

;; Within a charset, parse a single character, a character range or a
;; posix class. Returns the character (i.e. an integer), a cons (from
;; . to), or a symbol denoting the posix class
(defun rxt-parse-char-class-piece ()
  (let ((atom (rxt-parse-char-class-atom)))
    (if (and (integerp atom)
	     (looking-at "-[^]]"))
	(let ((r-end (rxt-maybe-parse-range-end)))
	  (if r-end (cons atom r-end) atom))
      atom)))

;; Parse a single character or posix class within a charset
;;
;; Doesn't treat ] or - specially -- that's taken care of in other
;; functions.
(defun rxt-parse-char-class-atom ()
  (or (and rxt-parse-pcre
	   (rxt-parse-char-class-atom/pcre))
      
      (rxt-token-case
       (rxt-posix-classes (intern (match-string 1)))
   
       ("\\[:[a-z]*:\\]"
	(error "Unknown posix class %s" (match-string 0)))
   
       ("\\[\\([.=]\\)[a-z]*\\1\\]"
	(error "%s collation syntax not supported" (match-string 0)))

       (".\\|\n" (string-to-char (match-string 0))))))

;; Parse backslash escapes inside PCRE character classes
(defun rxt-parse-char-class-atom/pcre ()
  (or (rxt-parse-escapes/pcre)
      (rxt-token-case
       ;; Backslash + digits => octal char
       ("\\\\\\([0-7]\\{1,3\\}\\)"    
	(string-to-number (match-string 1) 8))

       ;; Various character classes.
       ("\\\\d" 'digit)
       ("\\\\D" (rxt-negate 'digit))

       ("\\\\h" (rxt-char-set pcre-horizontal-whitespace-chars))
       ("\\\\H" (rxt-negate pcre-horizontal-whitespace-chars))

       ("\\\\s" (rxt-char-set pcre-whitespace-chars))
       ("\\\\S" (rxt-negate pcre-whitespace-chars))

       ("\\\\v" (rxt-char-set pcre-vertical-whitespace-chars))
       ("\\\\V" (rxt-negate pcre-vertical-whitespace-chars))

       ("\\\\w" rxt-pcre-word-chars)
       ("\\\\W" rxt-pcre-non-word-chars)

       ;; \b inside character classes = backspace
       ("\\\\b" ?\C-h)

       ;; Ignore other escapes
       ("\\\\\\(.\\)" (string-to-char (match-string 1))))))


;; Parse a possible range tail. Called when point is before a dash "-"
;; not followed by "]". Might fail, since the thing after the "-"
;; could be a posix class rather than a character; in that case,
;; leaves point where it was and returns nil.
(defun rxt-maybe-parse-range-end ()
  (let (r-end pos)
    (save-excursion
      (forward-char)
      (setq r-end (rxt-parse-char-class-atom)
	    pos (point)))

      (if (integerp r-end)
	  ;; This is a range: move after it and return the ending character
	  (progn
	    (goto-char pos)
	    r-end)
	;; Not a range.
	nil)))


;;; Public interface
(defun rxt-parse-re (re &optional pcre type)
  (let ((rxt-parse-pcre pcre)
	(rxt-subgroup-count 0)
	(case-fold-search nil))
    (with-temp-buffer
      (insert re)
      (goto-char (point-min))
      (let ((parse (rxt-parse-exp)))
	(case type
	  ((sre) (rxt-adt->sre parse))
	  ((rx) (rxt-adt->rx parse))
	  (t parse))))))

(defmacro rxt-value (expr)
  (let ((val (make-symbol "val"))
	(str (make-symbol "str")))
    `(let ((,val ,expr))
       (if (called-interactively-p 'any)
	   (let ((,str (format "%S" ,val)))
	     (message "%s" ,str)
	     (kill-new ,str))
	 ,val))))

(defun rxt-interactive (prompt)
  (list
   (if (use-region-p)
       (buffer-substring-no-properties (region-beginning) (region-end))
     (read-string prompt))))
  
(defun rxt-elisp->rx (el)
  (interactive (rxt-interactive "Elisp regexp: "))
  (rxt-value (rxt-parse-re el nil 'rx)))

(defun rxt-elisp->sre (el)
  (interactive (rxt-interactive "Elisp regexp: "))
  (rxt-value (rxt-parse-re el nil 'sre)))

(defun rxt-pcre->rx (pcre)
  (interactive (rxt-interactive "PCRE regexp: "))
  (rxt-value (rxt-parse-re pcre t 'rx)))

(defun rxt-pcre->sre (pcre)
  (interactive (rxt-interactive "PCRE regexp: "))
  (rxt-value (rxt-parse-re pcre t 'sre)))

(defun rxt-pcre->elisp (pcre)
  (interactive (rxt-interactive "PCRE regexp: "))
  (rxt-value (rx-to-string (rxt-pcre->rx pcre) t)))

(defun rxt-elisp->pcre (el)
  (interactive (rxt-interactive "Elisp regexp: "))
  (rxt-value (rxt-adt->pcre (rxt-parse-re el nil))))

(defun rxt-pcre->strings (pcre)
  (interactive (rxt-interactive "PCRE regexp: "))
  (rxt-value (rxt-adt->strings (rxt-parse-re pcre t))))

(defun rxt-elisp->strings (el)
  (interactive (rxt-interactive "Elisp regexp: "))
  (rxt-value (rxt-adt->strings (rxt-parse-re el nil))))

;;; testing purposes only
(defun rxt-test (re &optional pcre)
  (interactive "x")
  (insert (format "%S\n" re))
  (let ((adt (rxt-parse-re re pcre)))
    (insert (format "%S\n\n" (rx-to-string (rxt-adt->rx adt) t)))
    (insert (format "%s\n\n" (rxt-adt->pcre adt)))
    (insert (format "%S\n\n\n" (rxt-adt->rx adt)))))
  
(defun rxt-pcre-test (pcre)
  (interactive "s")
  (rxt-test pcre t))

;; (let ((rxt-parse-pcre t))
;;   (let ((rx (rxt-parse-re "(?:cat(?:aract|erpillar|))")))
;;     (message "%S\n%S" rx (rx-to-string rx))))


;; (with-temp-buffer
;;   (insert "\\x41-\\x50\\x{070}[:alnum:]foo]")
;;   (goto-char 0)
;;   (let* ((rxt-parse-pcre t)
;; 	 (result (rxt-parse-char-class))
;; 	 (chars (rxt-char-set-chars result))
;; 	 (ranges (rxt-char-set-ranges result))
;; 	 (classes (rxt-char-set-classes result))
;; 	 (negated (rxt-negated result)))
;;     (message "Negated: %s\nChars: %s\nRanges: %s\nClasses: %s"
;; 	     negated
;; 	     (mapconcat #'char-to-string chars "")
;; 	     (mapconcat
;; 	      (lambda (range)
;; 		(let ((begin (car range))
;; 		      (end (cdr range)))
;; 		  (format "%c-%c" begin end)))
;; 	      ranges ", ")
;; 	     (mapconcat #'symbol-name classes ", "))))


;;;; RE-Builder extensions from re-builder.el -- to be turned into advice
(defun reb-update-modestring ()
  "Update the variable `reb-mode-string' displayed in the mode line."
  (setq reb-mode-string
	(concat
	 (format " (%s)" reb-re-syntax)
	 (if reb-subexp-mode
             (format " (subexp %s)" (or reb-subexp-displayed "-"))
	   "")
	 (if (not (reb-target-binding case-fold-search))
	     " Case"
	   "")))
  (force-mode-line-update))

(defun reb-change-syntax (&optional syntax)
  "Change the syntax used by the RE Builder.
Optional argument SYNTAX must be specified if called non-interactively."
  (interactive
   (list (intern
	  (completing-read (format "Select syntax (%s): " reb-re-syntax)
			   '("read" "string" "pcre" "sregex" "rx")
			   nil t "" nil (symbol-name reb-re-syntax)))))

  (if (memq syntax '(read string pcre lisp-re sregex rx))
      (let ((buffer (get-buffer reb-buffer)))
	(setq reb-re-syntax syntax)
	(when buffer
          (with-current-buffer reb-target-buffer
	    (case syntax
	      ((rx)
	       (setq reb-regexp-src
		     (format "'%S"
			     (rxt-elisp->rx reb-regexp))))
	      ((pcre)
	       (setq reb-regexp-src (rxt-elisp->pcre reb-regexp)))))
	  (with-current-buffer buffer
            (reb-initialize-buffer))))
    (error "Invalid syntax: %s" syntax)))

(defun reb-read-regexp ()
  "Read current RE."
  (save-excursion
    (cond ((eq reb-re-syntax 'read)
	   (goto-char (point-min))
	   (read (current-buffer)))

	  ((eq reb-re-syntax 'string)
	   (goto-char (point-min))
	   (re-search-forward "\"")
	   (let ((beg (point)))
	     (goto-char (point-max))
	     (re-search-backward "\"")
	     (buffer-substring-no-properties beg (point))))

	  ((eq reb-re-syntax 'pcre)
	   (goto-char (point-min))
	   (skip-syntax-forward "-")
	   (let ((beg (point)))
	     (goto-char (point-max))
	     (skip-syntax-backward "-")
	     (buffer-substring-no-properties beg (point))))

	  ((or (reb-lisp-syntax-p) (eq reb-re-syntax 'pcre))
	   (buffer-string)))))

(defun reb-insert-regexp ()
  "Insert current RE."

  (let ((re (or (reb-target-binding reb-regexp)
		(reb-empty-regexp))))
  (cond ((eq reb-re-syntax 'read)
	 (print re (current-buffer)))
	((eq reb-re-syntax 'pcre)
	 (insert "\n"
		 (or (reb-target-binding reb-regexp-src)
		     (reb-empty-regexp))
		 "\n"))
	((eq reb-re-syntax 'string)
	 (insert "\n\"" re "\""))
	;; For the Lisp syntax we need the "source" of the regexp
	((reb-lisp-syntax-p)
	 (insert (or (reb-target-binding reb-regexp-src)
		     (reb-empty-regexp)))))))

(defun reb-cook-regexp (re)
  "Return RE after processing it according to `reb-re-syntax'."
  (cond ((eq reb-re-syntax 'lisp-re)
	 (when (fboundp 'lre-compile-string)
	   (lre-compile-string (eval (car (read-from-string re))))))
	((eq reb-re-syntax 'sregex)
	 (apply 'sregex (eval (car (read-from-string re)))))
	((eq reb-re-syntax 'rx)
	 (rx-to-string (eval (car (read-from-string re))) t))
	((eq reb-re-syntax 'pcre)
	 (rxt-pcre->elisp re))
	(t re)))

(defun reb-update-regexp ()
  "Update the regexp for the target buffer.
Return t if the (cooked) expression changed."
  (let* ((re-src (reb-read-regexp))
	 (re (reb-cook-regexp re-src)))
    (with-current-buffer reb-target-buffer
      (let ((oldre reb-regexp))
	(prog1
	    (not (string= oldre re))
	  (setq reb-regexp re)
	  ;; Only update the source re for the lisp formats
	  (when (or (reb-lisp-syntax-p) (eq reb-re-syntax 'pcre))
	    (setq reb-regexp-src re-src)))))))



(provide 'rxt)
