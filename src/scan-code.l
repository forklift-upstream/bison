/* Bison Action Scanner                             -*- C -*-

   Copyright (C) 2006 Free Software Foundation, Inc.

   This file is part of Bison, the GNU Compiler Compiler.

   This program is free software; you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation; either version 2 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, write to the Free Software
   Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
   02110-1301  USA
*/

%option debug nodefault nounput noyywrap never-interactive
%option prefix="code_" outfile="lex.yy.c"

%{
/* Work around a bug in flex 2.5.31.  See Debian bug 333231
   <http://bugs.debian.org/cgi-bin/bugreport.cgi?bug=333231>.  */
#undef code_wrap
#define code_wrap() 1

#define FLEX_PREFIX(Id) code_ ## Id
#include "flex-scanner.h"
#include "reader.h"
#include "getargs.h"
#include <assert.h>
#include <get-errno.h>
#include <quote.h>

#include "scan-code.h"

/* The current calling start condition: SC_RULE_ACTION or
   SC_SYMBOL_ACTION. */
# define YY_DECL const char *code_lex (int sc_context)
YY_DECL;

#define YY_USER_ACTION  location_compute (loc, &loc->end, yytext, yyleng);

static void handle_action_dollar (char *cp, location loc);
static void handle_action_at (char *cp, location loc);
static location the_location;
static location *loc = &the_location;

/* The rule being processed. */
symbol_list *current_rule;
%}
 /* C and C++ comments in code. */
%x SC_COMMENT SC_LINE_COMMENT
 /* Strings and characters in code. */
%x SC_STRING SC_CHARACTER
 /* Whether in a rule or symbol action.  Specifies the translation
    of $ and @.  */
%x SC_RULE_ACTION SC_SYMBOL_ACTION


/* POSIX says that a tag must be both an id and a C union member, but
   historically almost any character is allowed in a tag.  We disallow
   NUL and newline, as this simplifies our implementation.  */
tag	 [^\0\n>]+

/* Zero or more instances of backslash-newline.  Following GCC, allow
   white space between the backslash and the newline.  */
splice	 (\\[ \f\t\v]*\n)*

%%

%{
  /* Nesting level of the current code in braces.  */
  int braces_level IF_LINT (= 0);

  /* This scanner is special: it is invoked only once, henceforth
     is expected to return only once.  This initialization is
     therefore done once per action to translate. */
  assert (sc_context == SC_SYMBOL_ACTION
	  || sc_context == SC_RULE_ACTION
	  || sc_context == INITIAL);
  BEGIN sc_context;
%}

  /*------------------------------------------------------------.
  | Scanning a C comment.  The initial `/ *' is already eaten.  |
  `------------------------------------------------------------*/

<SC_COMMENT>
{
  "*"{splice}"/"  STRING_GROW; BEGIN sc_context;
}


  /*--------------------------------------------------------------.
  | Scanning a line comment.  The initial `//' is already eaten.  |
  `--------------------------------------------------------------*/

<SC_LINE_COMMENT>
{
  "\n"		 STRING_GROW; BEGIN sc_context;
  {splice}	 STRING_GROW;
}


  /*--------------------------------------------.
  | Scanning user-code characters and strings.  |
  `--------------------------------------------*/

<SC_CHARACTER,SC_STRING>
{
  {splice}|\\{splice}.	STRING_GROW;
}

<SC_CHARACTER>
{
  "'"		STRING_GROW; BEGIN sc_context;
}

<SC_STRING>
{
  "\""		STRING_GROW; BEGIN sc_context;
}


<SC_RULE_ACTION,SC_SYMBOL_ACTION>{
  "'" {
    STRING_GROW;
    BEGIN SC_CHARACTER;
  }
  "\"" {
    STRING_GROW;
    BEGIN SC_STRING;
  }
  "/"{splice}"*" {
    STRING_GROW;
    BEGIN SC_COMMENT;
  }
  "/"{splice}"/" {
    STRING_GROW;
    BEGIN SC_LINE_COMMENT;
  }
}

<SC_RULE_ACTION>
{
  "$"("<"{tag}">")?(-?[0-9]+|"$")   handle_action_dollar (yytext, *loc);
  "@"(-?[0-9]+|"$")		    handle_action_at (yytext, *loc);

  "$"  {
    warn_at (*loc, _("stray `$'"));
    obstack_sgrow (&obstack_for_string, "$][");
  }
  "@"  {
    warn_at (*loc, _("stray `@'"));
    obstack_sgrow (&obstack_for_string, "@@");
  }

  "{"  STRING_GROW; ++braces_level;
  "}"  {
    bool outer_brace = --braces_level < 0;

    /* As an undocumented Bison extension, append `;' before the last
       brace in braced code, so that the user code can omit trailing
       `;'.  But do not append `;' if emulating Yacc, since Yacc does
       not append one.

       FIXME: Bison should warn if a semicolon seems to be necessary
       here, and should omit the semicolon if it seems unnecessary
       (e.g., after ';', '{', or '}', each followed by comments or
       white space).  Such a warning shouldn't depend on --yacc; it
       should depend on a new --pedantic option, which would cause
       Bison to warn if it detects an extension to POSIX.  --pedantic
       should also diagnose other Bison extensions like %yacc.
       Perhaps there should also be a GCC-style --pedantic-errors
       option, so that such warnings are diagnosed as errors.  */
    if (outer_brace && ! yacc_flag)
      obstack_1grow (&obstack_for_string, ';');

    STRING_GROW;
  }
}

<SC_SYMBOL_ACTION>
{
  "$$"   obstack_sgrow (&obstack_for_string, "]b4_dollar_dollar[");
  "@$"   obstack_sgrow (&obstack_for_string, "]b4_at_dollar[");
}


  /*-----------------------------------------.
  | Escape M4 quoting characters in C code.  |
  `-----------------------------------------*/

<*>
{
  \$	obstack_sgrow (&obstack_for_string, "$][");
  \@	obstack_sgrow (&obstack_for_string, "@@");
  \[	obstack_sgrow (&obstack_for_string, "@{");
  \]	obstack_sgrow (&obstack_for_string, "@}");
}

  /*-----------------------------------------------------.
  | By default, grow the string obstack with the input.  |
  `-----------------------------------------------------*/

<*>.|\n	STRING_GROW;

 /* End of processing. */
<*><<EOF>>	 {
                   obstack_1grow (&obstack_for_string, '\0');
		   return obstack_finish (&obstack_for_string);
                 }

%%

/* Keeps track of the maximum number of semantic values to the left of
   a handle (those referenced by $0, $-1, etc.) are required by the
   semantic actions of this grammar. */
int max_left_semantic_context = 0;


/*------------------------------------------------------------------.
| TEXT is pointing to a wannabee semantic value (i.e., a `$').      |
|                                                                   |
| Possible inputs: $[<TYPENAME>]($|integer)                         |
|                                                                   |
| Output to OBSTACK_FOR_STRING a reference to this semantic value.  |
`------------------------------------------------------------------*/

static void
handle_action_dollar (char *text, location loc)
{
  const char *type_name = NULL;
  char *cp = text + 1;
  int rule_length = symbol_list_length (current_rule->next);

  /* Get the type name if explicit. */
  if (*cp == '<')
    {
      type_name = ++cp;
      while (*cp != '>')
	++cp;
      *cp = '\0';
      ++cp;
    }

  if (*cp == '$')
    {
      if (!type_name)
	type_name = symbol_list_n_type_name_get (current_rule, loc, 0);
      if (!type_name && typed)
	complain_at (loc, _("$$ of `%s' has no declared type"),
		     current_rule->sym->tag);
      if (!type_name)
	type_name = "";
      obstack_fgrow1 (&obstack_for_string,
		      "]b4_lhs_value([%s])[", type_name);
      current_rule->used = true;
    }
  else
    {
      long int num;
      set_errno (0);
      num = strtol (cp, 0, 10);
      if (INT_MIN <= num && num <= rule_length && ! get_errno ())
	{
	  int n = num;
	  if (1-n > max_left_semantic_context)
	    max_left_semantic_context = 1-n;
	  if (!type_name && n > 0)
	    type_name = symbol_list_n_type_name_get (current_rule, loc, n);
	  if (!type_name && typed)
	    complain_at (loc, _("$%d of `%s' has no declared type"),
			 n, current_rule->sym->tag);
	  if (!type_name)
	    type_name = "";
	  obstack_fgrow3 (&obstack_for_string,
			  "]b4_rhs_value(%d, %d, [%s])[",
			  rule_length, n, type_name);
	  symbol_list_n_used_set (current_rule, n, true);
	}
      else
	complain_at (loc, _("integer out of range: %s"), quote (text));
    }
}


/*------------------------------------------------------.
| TEXT is a location token (i.e., a `@...').  Output to |
| OBSTACK_FOR_STRING a reference to this location.      |
`------------------------------------------------------*/

static void
handle_action_at (char *text, location loc)
{
  char *cp = text + 1;
  int rule_length = symbol_list_length (current_rule->next);
  locations_flag = true;

  if (*cp == '$')
    obstack_sgrow (&obstack_for_string, "]b4_lhs_location[");
  else
    {
      long int num;
      set_errno (0);
      num = strtol (cp, 0, 10);

      if (INT_MIN <= num && num <= rule_length && ! get_errno ())
	{
	  int n = num;
	  obstack_fgrow2 (&obstack_for_string, "]b4_rhs_location(%d, %d)[",
			  rule_length, n);
	}
      else
	complain_at (loc, _("integer out of range: %s"), quote (text));
    }
}


/*-------------------------.
| Initialize the scanner.  |
`-------------------------*/

/* Translate the dollars and ats in \a a, whose location is l.
   Depending on the \a sc_context (SC_RULE_ACTION, SC_SYMBOL_ACTION,
   INITIAL), the processing is different.  */

static const char *
translate_action (int sc_context, const char *a, location l)
{
  const char *res;
  static bool initialized = false;
  if (!initialized)
    {
      obstack_init (&obstack_for_string);
      /* The initial buffer, never used. */
      yy_delete_buffer (YY_CURRENT_BUFFER);
      yy_flex_debug = 0;
      initialized = true;
    }

  loc->start = loc->end = l.start;
  yy_switch_to_buffer (yy_scan_string (a));
  res = code_lex (sc_context);
  yy_delete_buffer (YY_CURRENT_BUFFER);

  return res;
}

const char *
translate_rule_action (symbol_list *r, const char *a, location l)
{
  current_rule = r;
  return translate_action (SC_RULE_ACTION, a, l);
}

const char *
translate_symbol_action (const char *a, location l)
{
  return translate_action (SC_SYMBOL_ACTION, a, l);
}

const char *
translate_code (const char *a, location l)
{
  return translate_action (INITIAL, a, l);
}

/*-----------------------------------------------.
| Free all the memory allocated to the scanner.  |
`-----------------------------------------------*/

void
code_scanner_free (void)
{
  obstack_free (&obstack_for_string, 0);
  /* Reclaim Flex's buffers.  */
  yy_delete_buffer (YY_CURRENT_BUFFER);
}