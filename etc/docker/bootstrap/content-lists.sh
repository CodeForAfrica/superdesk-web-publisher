# Shared source of truth for the Default tenant's editorial homepage content
# list names. This file is SOURCED, not executed, by the ops/local bootstrap
# scripts that touch these lists:
#
#   - bootstrap-publisher.sh   creates them (manual, empty)
#   - seed-content-lists.sh    fills them with published articles
#
# Change a name here — or add/remove one — and both the create and the seed
# follow, so the set lives in exactly one place. Edit only CONTENT_LIST_NAMES
# below; the SQL fragments are derived from it. A name may contain any character
# except a single quote (names are single-quoted straight into SQL).

# One list name per line; blank lines are ignored.
CONTENT_LIST_NAMES="Homepage — Hero
Homepage — Spotlight
Homepage — Latest
Homepage — Trending"

# Derive the one SQL fragment the scripts need, without arrays (POSIX sh):
#   CONTENT_LIST_NAMES_IN  ->  'A', 'B', 'C'
# It feeds both  name IN (...)  in seed-content-lists.sh and  unnest(ARRAY[...])
# in bootstrap-publisher.sh. Glob expansion is disabled for the split so a name
# like "News [live]" is taken literally, and IFS/-f are restored to whatever the
# sourcing script had.
CONTENT_LIST_NAMES_IN=""
_cln_sep=""
_cln_old_ifs="$IFS"
case $- in *f*) _cln_had_f=1 ;; *) _cln_had_f=0 ;; esac
set -f
IFS='
'
for _cln_name in $CONTENT_LIST_NAMES; do
  [ -n "$_cln_name" ] || continue
  CONTENT_LIST_NAMES_IN="${CONTENT_LIST_NAMES_IN}${_cln_sep}'${_cln_name}'"
  _cln_sep=", "
done
IFS="$_cln_old_ifs"
[ "$_cln_had_f" = 1 ] || set +f
unset _cln_sep _cln_name _cln_old_ifs _cln_had_f
