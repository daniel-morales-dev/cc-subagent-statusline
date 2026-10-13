#!/bin/bash
# subagent-statusline — Claude Code `subagentStatusLine` command.
# Renders one row per visible subagent:
#   type · name · Model · effort · ctx% · $est · elapsed · ✎edits
# Reads {"session_id","transcript_path","tasks":[...]} on stdin,
# writes one {"id","content"} JSON line per row to stdout.
#
# Cost is an ESTIMATE computed from transcript token usage at published rates
# (USD per MTok). Haiku 5.5 applies a 5x tier above 100k-token prompts.
# Prices: haiku-5-5 .10/.50/.01/.125 · opus-5-5 4/20/.20/5 · sonnet-5-5 2/10/.20/2.50
set -u

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
tpath=$(printf '%s' "$input" | jq -r '.transcript_path // empty')

subdir=""
if [ -n "$tpath" ] && [ -n "$sid" ]; then
  subdir="${tpath%.jsonl}/subagents"
  [ -d "$subdir" ] || subdir=""
fi

# description -> transcript file, via the tiny agent-*.meta.json files
declare -A AFILE=()
if [ -n "$subdir" ]; then
  for m in "$subdir"/agent-*.meta.json; do
    [ -e "$m" ] || continue
    d=$(jq -r '.description // empty' "$m" 2>/dev/null)
    h=${m##*/agent-}; h=${h%.meta.json}
    [ -n "$d" ] && AFILE["$d"]="$subdir/agent-$h.jsonl"
  done
fi

CACHEDIR="/tmp/cc-subagent-statusline-v2.d"
mkdir -p "$CACHEDIR" 2>/dev/null

fmt_duration() {
  local s=$1
  if [ "$s" -lt 60 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%dm%02ds' $((s/60)) $((s%60))
  else printf '%dh%02dm' $((s/3600)) $(((s%3600)/60)); fi
}

now=$(date +%s)

while IFS= read -r t; do
  [ -n "$t" ] || continue
  IFS=$'\x1f' read -r id atype aname model effort tok cw st status desc < <(
    printf '%s' "$t" | jq -r '[(.id//""),(.agentType//.type//""),(.label//.description//.name//""),(.model//""),(.effort//""|tostring),(.tokenCount//0|tostring),(.contextWindowSize//0|tostring),(.startTime//0|tostring),(.status//""),(.description//"")]|join("\u001f")'
  )

  f=""; [ -n "$desc" ] && f="${AFILE[$desc]:-}"
  if [ -z "$f" ] && [ -n "$subdir" ] && [ -f "$subdir/agent-$id.jsonl" ]; then
    f="$subdir/agent-$id.jsonl"
  fi

  cost=""
  edits=""
  el=""
  start=""
  if [ -n "$f" ] && [ -f "$f" ]; then
    mt=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    h=${f##*/agent-}; h=${h%.jsonl}
    cf="$CACHEDIR/$h"
    if [ -f "$cf" ] && [ "$(head -1 "$cf" 2>/dev/null)" = "$mt" ]; then
      read -r _ start cost edits < "$cf" || true
      case "$start" in ''|*[!0-9]*) start=0;; esac
      [ "$cost" = "-" ] && cost=""
    else
      cost=$(jq -rs --arg m "$model" '
        [ .[] | select(type=="object" and .type=="assistant") | .message // empty | select(type=="object" and .usage!=null) ]
        | map(
            (.model // $m // "") as $mm | .usage as $u |
            ( ($u.input_tokens//0)+($u.cache_read_input_tokens//0)+($u.cache_creation_input_tokens//0) ) as $ps |
            ( if (($mm|test("haiku")) and ($ps>=100000)) then 5 else 1 end ) as $t |
            ( if ($mm|test("haiku")) then {i:0.1,o:0.5,cr:0.01,cw:0.125}
              elif ($mm|test("opus")) then {i:4,o:20,cr:0.2,cw:5}
              elif ($mm|test("sonnet")) then {i:2,o:10,cr:0.2,cw:2.5}
              else null end ) as $p |
            if $p == null then 0 else $t*( ($u.input_tokens//0)*$p.i + ($u.output_tokens//0)*$p.o + ($u.cache_read_input_tokens//0)*$p.cr + ($u.cache_creation_input_tokens//0)*$p.cw )/1000000 end
          )
        | (add // 0) * 1000 | round / 1000
      ' "$f" 2>/dev/null) || cost=""
      edits=$(grep -o '"type":"tool_use","id":"[^"]*","name":"\(Edit\|Write\|MultiEdit\|NotebookEdit\)"' "$f" 2>/dev/null | wc -l)
      ts=$(head -1 "$f" 2>/dev/null | jq -r '.timestamp // empty' 2>/dev/null)
      start=0
      [ -n "$ts" ] && start=$(date -d "$ts" +%s 2>/dev/null || echo 0)
      case "$start" in ''|*[!0-9]*) start=0;; esac
      printf '%s %s %s %s\n' "$mt" "${start:-0}" "${cost:--}" "$edits" > "$cf" 2>/dev/null
    fi
    end=$mt
    [ "$status" = "running" ] && end=$now
  else
    end=$now
  fi

  case "$st" in ''|*[!0-9]*) st=0;; esac
  if [ "$st" -gt 0 ]; then
    el=$(( (end*1000 - st) / 1000 ))
  elif [ "${start:-0}" -gt 0 ] 2>/dev/null; then
    el=$(( end - start ))
  fi
  if [ -n "$el" ]; then
    [ "$el" -lt 0 ] && el=0
    el=$(fmt_duration "$el")
  fi

  mdisp="$model"
  if [ -n "$model" ]; then
    mdisp=$(printf '%s' "$model" | jq -Rr 'sub("^claude-";"") | if test("^[a-z]+-[0-9]+-[0-9]+$") then capture("(?<fam>[a-z]+)-(?<maj>[0-9]+)-(?<min>[0-9]+)") | "\((.fam[0:1]|ascii_upcase))\(.fam[1:]) \(.maj).\(.min)" else . end' 2>/dev/null) || mdisp="$model"
  fi

  pct=""
  if [ "$cw" -gt 0 ] 2>/dev/null && [ "$tok" -gt 0 ] 2>/dev/null; then
    p=$(( 100 * tok / cw ))
    C=34
    [ "$p" -ge 60 ] && C=214
    [ "$p" -ge 85 ] && C=196
    if [ "$p" -eq 0 ]; then
      pct=$(printf '\033[38;5;%sm<1%%\033[0m' "$C")
    else
      pct=$(printf '\033[38;5;%sm%s%%\033[0m' "$C" "$p")
    fi
  fi

  cash=""
  if [ -n "$cost" ] && [ "$cost" != "-" ]; then
    C=$(awk -v v="$cost" 'BEGIN{print (v>3)?196:(v>1)?214:245}')
    cash=$(printf '\033[38;5;%sm$%s\033[0m' "$C" "$cost")
  fi
  MK=""
  case "${status:-}" in
    completed) MK=$(printf '\033[32m✓\033[0m ') ;;
    failed|killed|error) MK=$(printf '\033[31m✕\033[0m ') ;;
  esac
  parts="$MK$(printf '\033[36m%s\033[0m' "$atype")"
  [ -n "$aname" ] && parts="$parts · $aname"
  [ -n "$mdisp" ] && parts="$parts · $mdisp"
  case "$effort" in
    ''|null) effort="" ;;
    *[!0-9]*) ;;
    *) [ "$effort" -ge 1000 ] 2>/dev/null && effort="$((effort/1000))k" ;;
  esac
  [ -n "$effort" ] && parts="$parts · $(printf '\033[35m%s\033[0m' "$effort")"
  [ -n "$pct" ] && parts="$parts · $pct"
  [ -n "$cash" ] && parts="$parts · $cash"
  [ -n "$el" ] && parts="$parts · $(printf '\033[2m%s\033[0m' "$el")"
  [ -n "$edits" ] && [ "$edits" != "0" ] && parts="$parts · $(printf '\033[32m✎%s\033[0m' "$edits")"

  jq -cn --arg id "$id" --arg c "$parts" '{id:$id,content:$c}'
done < <(printf '%s' "$input" | jq -c '.tasks[]?' 2>/dev/null)
