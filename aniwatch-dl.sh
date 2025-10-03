#!/usr/bin/env bash
#
# Download anime from a self-hosted AniWatch API instance
#
#/ Usage:
#/   ./aniwatch-dl.sh -a <anime_name> [-i <anime_id>] [-e <episode_selection>] \
#/                    [-S <server_keyword>] [-r <keyword>] [-o <type>] [-L <langs>] \
#/                    [-t <num_threads>] [-l] [-d] [-T <timeout_secs>]
#/
#/ Options:
#/   -a <name>               Anime name to search for (ignored if -i is used).
#/   -i <anime_id>           Specify anime ID directly (e.g., "attack-on-titan-112").
#/   -e <selection>          Episode selection (e.g., "1,3-5", "*", "L3"). Prompts if omitted.
#/   -S <server_keyword>     Optional, keyword for preferred server (e.g., "megacloud", "vidstreaming").
#/   -r <keyword>            Optional, resolution keyword to select (e.g., "720", "1080", "360").
#/   -o <type>               Optional, audio type: "sub" or "dub". Default: "sub".
#/   -L <langs>              Optional, subtitle languages (comma-separated codes like "eng,spa",
#/                           or "all", "none", "default"). Default: "default".
#/   -t <num>                Optional, parallel download threads. Default: 4.
#/   -T <secs>               Optional, timeout for segment downloads (GNU Parallel).
#/   -l                      Optional, list m3u8/mp4 links without downloading.
#/   -d                      Enable debug mode.
#/   -h | --help             Display this help message.

# --- Configuration ---
set -e
set -u
# set -o pipefail # Uncomment for stricter error handling in pipelines

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
if ! [ -t 1 ]; then
  RED='' GREEN='' YELLOW='' BLUE='' PURPLE='' CYAN='' BOLD='' NC=''
fi

# --- Global Variables ---
_SCRIPT_NAME="$(basename "$0")"

_ANIWATCH_API_BASE_URL=""
_ANIME_TITLE="unknown_anime"
_ANIME_ID=""
_EPISODE_SELECTION=""
_SERVER_KEYWORD=""
_RESOLUTION_KEYWORD=""
_AUDIO_TYPE="sub"
_SUBTITLE_LANGS_PREF="default"
_NUM_THREADS=4
_SEGMENT_TIMEOUT=""
_LIST_LINKS_ONLY=false
_DEBUG_MODE=false

_USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
_VIDEO_DIR_PATH="${ANIWATCH_DL_VIDEO_DIR:-$HOME/Videos/AniWatchAnime}"
_TEMP_DIR_PARENT="${ANIWATCH_DL_TMP_DIR:-${_VIDEO_DIR_PATH}/.tmp}"

_CURL="" _JQ="" _FZF="" _FFMPEG="" _PARALLEL="" _MKTEMP=""
all_episodes_json_array_for_padding="[]"
_temp_dirs_to_clean=()

# --- Helper Functions ---
usage() { printf "%b\n" "$(grep '^#/' "$0" | cut -c4-)" && exit 0; }
print_info() { [[ "$_LIST_LINKS_ONLY" == false ]] && printf "%b\n" "${GREEN}ℹ ${NC}$1" >&2; }
print_warn() { [[ "$_LIST_LINKS_ONLY" == false ]] && printf "%b\n" "${YELLOW}⚠ WARNING: ${NC}$1" >&2; }
print_error() { printf "%b\n" "${RED}✘ ERROR: ${NC}$1" >&2; exit 1; }
print_debug() { [[ "$_DEBUG_MODE" == true && "$_LIST_LINKS_ONLY" == false ]] && printf "%b\n" "${BLUE}DEBUG: ${NC}$1" >&2; }

# --- Cleanup Trap ---
trap '
  if [[ "$_DEBUG_MODE" == false && ${#_temp_dirs_to_clean[@]} -gt 0 ]]; then
    print_info "Cleaning up ${#_temp_dirs_to_clean[@]} temporary director(y/ies)..."
    for temp_dir in "${_temp_dirs_to_clean[@]}"; do
      [[ -d "$temp_dir" ]] && rm -rf "$temp_dir"
    done
  fi
' EXIT INT TERM

# --- Core Functions ---

#
# Sets the API base URL from the ANIWATCH_API_URL environment variable.
# Exits with an error if the URL is not set.
#
initialize_api_url() {
  _ANIWATCH_API_BASE_URL="${ANIWATCH_API_URL:-}"
  if [[ -z "$_ANIWATCH_API_BASE_URL" ]]; then
    print_error "AniWatch API URL is not set. Please set the ANIWATCH_API_URL environment variable."
  fi
  _ANIWATCH_API_BASE_URL="${_ANIWATCH_API_BASE_URL%/}"
}

#
# Checks for the presence of all required command-line tools.
# Exits with an error if any dependency is missing.
#
check_deps() {
  print_info "Checking required tools..."
  for dep_name in curl jq fzf ffmpeg parallel mktemp; do
    declare -g "_${dep_name^^}=$(command -v "$dep_name" || print_error "$dep_name not found.")"
  done
  print_info "${GREEN}✓ All required tools found.${NC}"
}

#
# Sanitizes a string to be a valid filename.
# $1: The string to sanitize.
#
sanitize_filename() {
  echo "$1" | sed -E 's/[^[:alnum:] ,+\-\)\(._@#%&=]/_/g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -s '_'
}

#
# Parses command-line arguments and sets global variables.
# $@: All command-line arguments passed to the script.
#
parse_args() {
  OPTIND=1
  while getopts ":hlda:i:e:S:r:o:t:T:L:" opt; do
    case $opt in
    a) _ANIME_SEARCH_NAME="$OPTARG" ;;
    i) _ANIME_ID_ARG="$OPTARG" ;;
    e) _EPISODE_SELECTION="$OPTARG" ;;
    S) _SERVER_KEYWORD="$OPTARG" ;;
    r) _RESOLUTION_KEYWORD="$OPTARG" ;;
    o) _AUDIO_TYPE=$(echo "$OPTARG" | tr '[:upper:]' '[:lower:]'); if [[ "$_AUDIO_TYPE" != "sub" && "$_AUDIO_TYPE" != "dub" ]]; then print_error "Invalid audio type: 'sub' or 'dub'."; fi ;;
    L) _SUBTITLE_LANGS_PREF="$OPTARG" ;;
    t) _NUM_THREADS="$OPTARG"; if ! [[ "$_NUM_THREADS" =~ ^[1-9][0-9]*$ ]]; then print_error "-t: Must be a positive integer."; fi ;;
    T) _SEGMENT_TIMEOUT="$OPTARG"; if ! [[ "$_SEGMENT_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then print_error "-T: Must be a positive integer."; fi ;;
    l) _LIST_LINKS_ONLY=true ;;
    d) _DEBUG_MODE=true; print_info "${YELLOW}Debug mode enabled.${NC}"; set -x ;;
    h) usage ;;
    \?) print_error "Invalid option: -$OPTARG" ;;
    :) print_error "Option -$OPTARG requires an argument." ;;
    esac
  done
  if [[ -z "${_ANIME_SEARCH_NAME:-}" && -z "${_ANIME_ID_ARG:-}" ]]; then print_error "No anime specified (-a or -i required)."; fi
  if [[ -n "${_ANIME_SEARCH_NAME:-}" && -n "${_ANIME_ID_ARG:-}" ]]; then print_warn "Both -a and -i provided. Using -i."; _ANIME_SEARCH_NAME=""; fi
}

#
# Performs a raw GET request to the AniWatch API.
# $1: The API endpoint path (e.g., "/api/v2/hianime/search").
# $2: Optional query string (e.g., "q=naruto").
#
api_get_raw() {
  local endpoint_path="$1" query_string="${2:-}" full_url response http_code
  full_url="${_ANIWATCH_API_BASE_URL}${endpoint_path}"
  [[ -n "$query_string" ]] && full_url="${full_url}?${query_string}"
  print_debug "API GET raw: $full_url"

  local curl_opts_array=(-sSL -w "%{http_code}" --connect-timeout 15 --retry 2 --retry-delay 3)
  curl_opts_array+=(-H "Accept: application/json" -H "User-Agent: $_USER_AGENT")

  # The /sources endpoint requires a specific Referer to pass its own checks.
  if [[ "$endpoint_path" == *"/episode/sources"* ]]; then
      local referer="https://megacloud.club/"
      print_debug "Adding fixed Referer for API call to /sources: $referer"
      curl_opts_array+=(-H "Referer: $referer")
  fi

  local curl_stderr_file; curl_stderr_file=$("$_MKTEMP" --tmpdir aniwatch_dl_curl_stderr.XXXXXX)
  response=$("$_CURL" "${curl_opts_array[@]}" "$full_url" 2>"$curl_stderr_file")
  local curl_exit_code=$?; local curl_stderr; curl_stderr=$(<"$curl_stderr_file"); rm -f "$curl_stderr_file"
  if [[ $curl_exit_code -ne 0 ]]; then print_error "curl for $full_url failed (Code: $curl_exit_code). Stderr: $curl_stderr"; fi

  http_code="${response:${#response}-3}"; response="${response:0:${#response}-3}"
  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then print_error "API $full_url failed (HTTP: $http_code). Response: $response"; fi

  if echo "$response" | "$_JQ" -e 'has("success")' >/dev/null; then
    if [[ $(echo "$response" | "$_JQ" -r .success) != "true" ]]; then
      local api_err; api_err=$(echo "$response" | "$_JQ" -r '.message // .error // "Unknown API error"')
      print_error "API $full_url not successful. Msg: $api_err"
    fi
  else
    print_debug "API response for $full_url missing '.success' field. Proceeding as HTTP code was $http_code."
  fi
  echo "$response"
}

#
# Gets and extracts the '.data' field from an API response.
# $1: The API endpoint path.
# $2: Optional query string.
# $3: Optional jq filter to apply to the .data object (default: ".").
#
api_get_data() {
  local endpoint_path="$1" query_string="${2:-}" jq_filter="${3:-.}" raw_response data_obj
  raw_response=$(api_get_raw "$endpoint_path" "$query_string") || return 1
  if ! data_obj=$(echo "$raw_response" | "$_JQ" -e ".data | ${jq_filter}"); then
    print_error "Failed to extract '.data | ${jq_filter}' from API for $endpoint_path?$query_string. Raw: $raw_response"
  fi
  echo "$data_obj"
}

#
# Searches for an anime and prompts the user to select one using fzf.
# $1: The search term for the anime.
#
search_and_select_anime() {
  local search_term="$1" encoded_search_term anime_data_array_json selected_anime_json
  print_info "Searching for anime: ${BOLD}$search_term${NC}"
  encoded_search_term=$("$_JQ" -nr --arg str "$search_term" '$str|@uri')
  anime_data_array_json=$(api_get_data "/api/v2/hianime/search" "q=$encoded_search_term" ".animes") || return 1
  if [[ -z "$anime_data_array_json" || $(echo "$anime_data_array_json" | "$_JQ" -e 'length == 0') == "true" ]]; then
    print_error "No anime found for '$search_term'."
  fi

  local jq_preview_filter='
    "Title:     " + .name + " (" + .type + ")\n" +
    "ID:        " + .id + "\n" +
    "Duration:  " + .duration + "\n" +
    "Rating:    " + .rating + "\n" +
    "Sub/Dub:   " + (.episodes.sub|tostring) + "/" + (.episodes.dub|tostring)
  '
  selected_anime_json=$(echo "$anime_data_array_json" |
    "$_JQ" -r '.[] | ((.name // "N/A") + " (" + (.type // "N/A") + ")") + "\t" + (.|@json)' |
    "$_FZF" --ansi --height=40% --layout=reverse --info=inline --border --delimiter='\t' \
      --with-nth=1 --header="Search results for '$search_term'" --prompt="Select Anime> " \
      --preview="echo -E {2} | $_JQ -r '$jq_preview_filter'" --select-1 --exit-0 | sed 's/^[^\t]*\t//')
  if [[ -z "$selected_anime_json" ]]; then print_error "No anime selected."; fi

  _ANIME_ID=$("$_JQ" -r '.id' <<<"$selected_anime_json")
  _ANIME_TITLE=$("$_JQ" -r '.name // .id' <<<"$selected_anime_json")
  if [[ -z "$_ANIME_ID" || "$_ANIME_ID" == "null" ]]; then print_error "Could not extract anime ID."; fi
  _ANIME_TITLE=$(sanitize_filename "${_ANIME_TITLE}")
  print_info "${GREEN}✓ Selected Anime:${NC} ${BOLD}${_ANIME_TITLE}${NC} (ID: ${_ANIME_ID})"
}

#
# Fetches anime details by ID to get the title.
# $1: The anime ID.
#
fetch_anime_title_by_id() {
  print_info "Fetching details for anime ID: ${BOLD}$1${NC}"
  local info_json; info_json=$(api_get_data "/api/v2/hianime/anime/$1" "" ".anime.info") || return 1
  _ANIME_TITLE=$("$_JQ" -r '.name // .id' <<<"$info_json")
  _ANIME_TITLE=$(sanitize_filename "${_ANIME_TITLE}")
  print_info "${GREEN}✓ Anime Title:${NC} ${BOLD}${_ANIME_TITLE}${NC} (ID: $1)"
}

#
# Fetches the complete list of episodes for a given anime ID.
# $1: The anime ID.
#
get_episode_info_list() {
  print_info "Fetching episode list for ${BOLD}${_ANIME_TITLE}${NC}..."
  local episodes_data; episodes_data=$(api_get_data "/api/v2/hianime/anime/$1/episodes") || return 1
  local total_episodes; total_episodes=$("$_JQ" -r '.totalEpisodes // 0' <<<"$episodes_data")
  if [[ "$total_episodes" -eq 0 ]]; then print_warn "No episodes found."; echo "[]"; return 0; fi
  print_info "Found ${BOLD}$total_episodes${NC} episodes."

  all_episodes_json_array_for_padding=$("$_JQ" -c '[.episodes[] | {ep_num: (.number | tostring), stream_id: .episodeId, title: .title}]' <<<"$episodes_data")
  echo "$all_episodes_json_array_for_padding"
}

#
# Parses a user-provided selection string (e.g., "1,5-10,L3") into a JSON array of episode objects.
# $1: The episode selection string.
# $2: A JSON array of all available episode objects.
#
parse_episode_selection() {
  local selection_str="$1" all_episodes_json="$2" available_ep_nums_array=()
  local selected_episode_objects_json="[]" include_nums=() exclude_nums=() final_ep_nums=()
  mapfile -t available_ep_nums_array < <(echo "$all_episodes_json" | "$_JQ" -r '.[].ep_num' | sort -n)
  if [[ ${#available_ep_nums_array[@]} -eq 0 ]]; then print_warn "No available episodes for selection."; echo "[]"; return 0; fi

  IFS=',' read -ra parts <<<"$selection_str"
  for part in "${parts[@]}"; do
    part=$(echo "$part" | tr -d '[:space:]'); local target_list_ref="include_nums" pattern="$part"
    if [[ "$pattern" == "!"* ]]; then target_list_ref="exclude_nums"; pattern="${pattern#!}"; fi
    case "$pattern" in
    \*) if [[ "$target_list_ref" == "include_nums" ]]; then include_nums+=("${available_ep_nums_array[@]}"); else exclude_nums+=("${available_ep_nums_array[@]}"); fi ;;
    L[0-9]*) local n=${pattern#L}; if [[ "$n" -gt 0 ]]; then mapfile -t slice < <(printf '%s\n' "${available_ep_nums_array[@]}" | tail -n "$n"); if [[ "$target_list_ref" == "include_nums" ]]; then include_nums+=("${slice[@]}"); else exclude_nums+=("${slice[@]}"); fi; fi ;;
    F[0-9]*) local n=${pattern#F}; if [[ "$n" -gt 0 ]]; then mapfile -t slice < <(printf '%s\n' "${available_ep_nums_array[@]}" | head -n "$n"); if [[ "$target_list_ref" == "include_nums" ]]; then include_nums+=("${slice[@]}"); else exclude_nums+=("${slice[@]}"); fi; fi ;;
    [0-9]*-) local s=${pattern%-}; for ep in "${available_ep_nums_array[@]}"; do [[ "$ep" -ge "$s" ]] && { if [[ "$target_list_ref" == "include_nums" ]]; then include_nums+=("$ep"); else exclude_nums+=("$ep"); fi; }; done ;;
    -[0-9]*) local e=${pattern#-} ; for ep in "${available_ep_nums_array[@]}"; do [[ "$ep" -le "$e" ]] && { if [[ "$target_list_ref" == "include_nums" ]]; then include_nums+=("$ep"); else exclude_nums+=("$ep"); fi; }; done ;;
    [0-9]*-[0-9]*) local s e; s=$(awk -F- '{print $1}' <<<"$pattern"); e=$(awk -F- '{print $2}' <<<"$pattern"); if [[ "$s" -le "$e" ]]; then for ep in "${available_ep_nums_array[@]}"; do [[ "$ep" -ge "$s" && "$ep" -le "$e" ]] && { if [[ "$target_list_ref" == "include_nums" ]]; then include_nums+=("$ep"); else exclude_nums+=("$ep"); fi; }; done; fi ;;
    [0-9]*) if [[ " ${available_ep_nums_array[*]} " =~ " $pattern " ]]; then if [[ "$target_list_ref" == "include_nums" ]]; then include_nums+=("$pattern"); else exclude_nums+=("$pattern"); fi; else print_warn "Ep $pattern not found."; fi ;;
    *) print_warn "Unrecognized pattern: $pattern" ;;
    esac
  done

  mapfile -t unique_includes < <(printf '%s\n' "${include_nums[@]}" | sort -n -u)
  mapfile -t unique_excludes < <(printf '%s\n' "${exclude_nums[@]}" | sort -n -u)
  for inc_ep in "${unique_includes[@]}"; do if ! [[ " ${unique_excludes[*]} " =~ " $inc_ep " ]]; then final_ep_nums+=("$inc_ep"); fi; done

  if [[ ${#final_ep_nums[@]} -eq 0 ]]; then print_warn "No episodes remaining after parsing selection."; echo "[]"; return 0; fi
  local jq_ep_nums_array_str; jq_ep_nums_array_str=$("$_JQ" -ncR '[inputs]' < <(printf "%s\n" "${final_ep_nums[@]}"))
  selected_episode_objects_json=$("$_JQ" -c --argjson nums_to_select "$jq_ep_nums_array_str" '[.[] | select(.ep_num as $ep | $nums_to_select | index($ep) != null)]' <<<"$all_episodes_json")

  print_info "${GREEN}✓ Episodes to download:${NC} ${BOLD}$(echo "$selected_episode_objects_json" | "$_JQ" -r '[.[].ep_num] | join(", ")') (Total: $(echo "$selected_episode_objects_json" | "$_JQ" -r 'length'))${NC}"
  echo "$selected_episode_objects_json"
}

#
# Fetches available servers and stream URLs for a specific episode.
# $1: The episode stream ID.
# $2: The preferred audio type ("sub" or "dub").
# $3: Optional keyword to filter servers.
# $4: Optional episode number for logging purposes.
#
get_stream_details() {
  local ep_stream_id="$1" audio_pref="$2" server_keyword="$3" ep_num_for_log="${4:-}"
  local encoded_ep_id available_servers_json servers_for_audio_type chosen_server_name query_params_for_sources
  local sources_data video_url is_m3u8 subtitles_json referer_url

  print_debug "Fetching stream details for Ep ${ep_num_for_log:-$ep_stream_id} (Type: $audio_pref)..."
  encoded_ep_id=$("$_JQ" -nr --arg str "$ep_stream_id" '$str|@uri')
  available_servers_json=$(api_get_data "/api/v2/hianime/episode/servers" "animeEpisodeId=$encoded_ep_id") || return 1
  servers_for_audio_type=$("$_JQ" -c --arg pref "$audio_pref" '.[$pref] // []' <<<"$available_servers_json")

  if [[ "$audio_pref" == "dub" && $(echo "$servers_for_audio_type" | "$_JQ" -e 'length == 0') == "true" ]]; then
    print_warn "  No 'dub' servers for Ep $ep_num_for_log. Falling back to 'sub'..."
    audio_pref="sub"
    servers_for_audio_type=$("$_JQ" -c '(.sub // [])' <<<"$available_servers_json")
  fi
  if [[ $(echo "$servers_for_audio_type" | "$_JQ" -e 'length == 0') == "true" ]]; then print_warn "  No servers of type '$audio_pref' found."; return 1; fi

  local server_list; server_list=$("$_JQ" -r '.[] | .serverName' <<<"$servers_for_audio_type")
  if [[ -n "$server_keyword" ]]; then server_list=$(echo "$server_list" | grep -iF "$server_keyword" || true); fi
  if [[ -z "$server_list" ]]; then
      server_list=$("$_JQ" -r '.[] | .serverName' <<<"$servers_for_audio_type")
      [[ -n "$server_keyword" ]] && print_warn "  Server '$_SERVER_KEYWORD' not found; using first available."
  fi

  chosen_server_name=$(echo "$server_list" | head -n 1)
  if [[ -z "$chosen_server_name" ]]; then print_warn "  Could not select a server."; return 1; fi
  print_info "  Selected server: ${BOLD}${chosen_server_name}${NC}"

  query_params_for_sources="animeEpisodeId=$encoded_ep_id&server=${chosen_server_name}&category=${audio_pref}"
  sources_data=""
  for ((attempt=1; attempt<=3; attempt++)); do
    print_info "    Fetching sources (Attempt $attempt/3)..."
    sources_data=$(api_get_data "/api/v2/hianime/episode/sources" "$query_params_for_sources" "." || true)
    if [[ -n "$sources_data" ]]; then print_debug "    Successfully fetched sources on attempt $attempt."; break; fi
    if [[ $attempt -lt 3 ]]; then print_warn "    Failed to fetch sources. Waiting 5 seconds before retrying..."; sleep 5; fi
  done

  if [[ -z "$sources_data" ]]; then print_warn "  Failed to fetch sources for Ep $ep_num_for_log after 3 attempts."; return 1; fi

  video_url=$("$_JQ" -r '.sources[0].url // empty' <<<"$sources_data")
  is_m3u8=$("$_JQ" -r '.sources[0].isM3U8 // true | tostring' <<<"$sources_data" | head -n 1)
  subtitles_json=$("$_JQ" -c '.tracks // [] | map(select(.lang != "thumbnails"))' <<<"$sources_data")
  referer_url=$("$_JQ" -r '.headers.Referer // "https://megacloud.blog/"' <<<"$sources_data")
  print_debug "  Using download Referer: $referer_url"

  if [[ -z "$video_url" || "$video_url" == "null" ]]; then print_warn "  Video URL is empty for server '$chosen_server_name'."; return 1; fi
  print_info "    ${GREEN}✓ Video URL found.${NC} (M3U8: $is_m3u8)"

  "$_JQ" -ncr \
    --arg vu "$video_url" --argjson ism3u8 "$is_m3u8" \
    --argjson subs "$subtitles_json" --arg ru "$referer_url" \
    '{video_url: $vu, is_m3u8: $ism3u8, subtitles: $subs, referer_url: $ru}'
}

#
# Downloads a single file using curl with retries.
# $1: The URL to download.
# $2: The path to save the file to.
# $3: Optional Referer header string.
#
download_file() {
  local url="$1" outfile="$2" arg_referer="${3:-}"
  local referer_to_use="${referer_url:-$arg_referer}"

  local max_retries=3; local attempt=0; local success=false
  mkdir -p "$(dirname "$outfile")"
  local curl_opts_array=(-k -sSL --fail -o "$outfile" "$url")
  curl_opts_array+=(-H "User-Agent: $_USER_AGENT")
  curl_opts_array+=(--connect-timeout 15 --retry 2 --retry-delay 2)
  [[ -n "$_SEGMENT_TIMEOUT" ]] && curl_opts_array+=(--max-time "$_SEGMENT_TIMEOUT")
  if [[ -n "$referer_to_use" ]]; then curl_opts_array+=(-H "Referer: $referer_to_use"); fi

  for ((attempt = 1; attempt <= max_retries; attempt++)); do
    "$_CURL" "${curl_opts_array[@]}"
    if [[ $? -eq 0 && -s "$outfile" ]]; then success=true; break; else rm -f "$outfile"; sleep 2; fi
  done
  if [[ "$success" == false ]]; then rm -f "$outfile"; return 1; fi
  return 0
}

#
# Handles the entire HLS (M3U8) stream download and assembly process.
# $1: The URL of the master M3U8 playlist.
# $2: The final output path for the assembled video file.
# $3: The temporary directory to use for segments.
# $4: The Referer URL to use for downloads.
# $5: The episode title (for metadata).
# $6: The episode number (for metadata).
#
download_and_assemble_m3u8() {
  local master_m3u8_url="$1" output_video_path="$2" temp_dir="$3" referer_url="$4" episode_title="$5" episode_number="$6"
  local master_playlist_file="${temp_dir}/master.m3u8" selected_media_playlist_url=""
  local media_playlist_file="${temp_dir}/media_playlist.m3u8" segment_list_file="${temp_dir}/segments.txt"

  print_info "  Downloading Master M3U8..."
  if ! download_file "$master_m3u8_url" "$master_playlist_file" "$referer_url"; then return 1; fi

  local available_streams=(); local stream_info_line=""
  while IFS= read -r line; do
    if [[ "$line" == \#EXT-X-STREAM-INF:* ]]; then stream_info_line="$line"; elif [[ -n "$stream_info_line" && "$line" != \#* && -n "$line" ]]; then
      local res bw url; res=$(echo "$stream_info_line" | sed -n 's/.*RESOLUTION=\([^,]*\).*/\1/p'); bw=$(echo "$stream_info_line" | sed -n 's/.*BANDWIDTH=\([^,]*\).*/\1/p'); url="$line"
      if [[ -n "$res" && -n "$bw" && -n "$url" ]]; then available_streams+=("${res}|${bw}|${url}"); fi
      stream_info_line=""
    fi
  done <"$master_playlist_file"

  if [[ ${#available_streams[@]} -eq 0 ]]; then
    print_debug "  No variants in master playlist. Assuming it's a media playlist."
    cp "$master_playlist_file" "$media_playlist_file"; selected_media_playlist_url="$master_m3u8_url"
  else
    local chosen_stream_data="" filtered_streams=()
    if [[ -n "$_RESOLUTION_KEYWORD" ]]; then
      print_info "  Attempting to select stream with quality keyword: '${BOLD}${_RESOLUTION_KEYWORD}${NC}'"
      mapfile -t filtered_streams < <(printf '%s\n' "${available_streams[@]}" | grep -iF "$_RESOLUTION_KEYWORD")
      if [[ ${#filtered_streams[@]} -gt 0 ]]; then
        print_info "    Found ${#filtered_streams[@]} matching stream(s)."
        chosen_stream_data=$(printf '%s\n' "${filtered_streams[@]}" | sort -t'|' -k2,2nr | head -n1)
      else
        print_warn "    No stream matched keyword. Falling back to highest quality."
      fi
    fi
    if [[ -z "$chosen_stream_data" ]]; then
      print_info "  Selecting highest quality stream by default."
      chosen_stream_data=$(printf '%s\n' "${available_streams[@]}" | sort -t'|' -k2,2nr | head -n1)
    fi

    local chosen_res chosen_bw chosen_rel_url; chosen_res=$(echo "$chosen_stream_data" | awk -F'|' '{print $1}'); chosen_bw=$(echo "$chosen_stream_data" | awk -F'|' '{print $2}'); chosen_rel_url=$(echo "$chosen_stream_data" | awk -F'|' '{print $3}')
    print_info "  Selected Stream Quality: ${BOLD}${chosen_res}${NC} (Bandwidth: ${chosen_bw})"
    local master_m3u8_base_url; master_m3u8_base_url=$(dirname "$master_m3u8_url")
    if [[ "$chosen_rel_url" =~ ^https?:// ]]; then selected_media_playlist_url="$chosen_rel_url"; else selected_media_playlist_url="${master_m3u8_base_url%/}/${chosen_rel_url#/}"; fi
    print_info "  Downloading Media Playlist..."
    if ! download_file "$selected_media_playlist_url" "$media_playlist_file" "$referer_url"; then print_warn "  Failed media playlist DL"; return 1; fi
  fi

  local media_playlist_base_url; media_playlist_base_url=$(dirname "$selected_media_playlist_url")
  local segment_urls_for_dl=() local_segment_files_for_ffmpeg=()
  mapfile -t segment_lines < <(grep -v '^#' "$media_playlist_file" | grep -v '^$')

  if [[ ${#segment_lines[@]} -eq 0 ]]; then print_warn "  No segment data found in media playlist."; return 1; fi
  print_info "  Found ${#segment_lines[@]} segments to download."
  for seg_path_or_url in "${segment_lines[@]}"; do
    local full_seg_url segment_filename; seg_path_or_url=$(echo "$seg_path_or_url" | xargs)
    if [[ -z "$seg_path_or_url" ]]; then continue; fi
    if [[ "$seg_path_or_url" =~ ^https?:// ]]; then full_seg_url="$seg_path_or_url"; else full_seg_url="${media_playlist_base_url%/}/${seg_path_or_url#/}"; fi
    segment_urls_for_dl+=("$full_seg_url")
    segment_filename=$(basename "$seg_path_or_url"); segment_filename="${segment_filename%%\?*}"
    local_segment_files_for_ffmpeg+=("${temp_dir}/${segment_filename}")
    printf "file '%s'\n" "${segment_filename}" >>"$segment_list_file"
  done
  if [[ ${#segment_urls_for_dl[@]} -eq 0 ]]; then print_warn "  No valid segment URLs extracted."; return 1; fi

  print_info "  Downloading ${#segment_urls_for_dl[@]} segments using $_NUM_THREADS threads..."
  export referer_url _CURL _SEGMENT_TIMEOUT _USER_AGENT
  export -f download_file print_warn print_debug

  local parallel_joblog="${temp_dir}/parallel_dl.log" parallel_input_file="${temp_dir}/parallel_input.txt"
  >"$parallel_input_file"
  for i in "${!segment_urls_for_dl[@]}"; do printf "%s\t%s\n" "${segment_urls_for_dl[i]}" "${local_segment_files_for_ffmpeg[i]}" >>"$parallel_input_file"; done
  if [[ ! -s "$parallel_input_file" ]]; then print_warn "  Parallel input file empty."; return 1; fi

 "$_PARALLEL" --colsep '\t' -j "$_NUM_THREADS" --bar --joblog "$parallel_joblog" "download_file {1} {2}" < "$parallel_input_file" >&2

  local successful_dl; successful_dl=$(awk 'NR > 1 && $7 == 0 {c++} END {print c+0}' "$parallel_joblog")
  if [[ "$successful_dl" -ne "${#segment_urls_for_dl[@]}" ]]; then print_warn "  $((${#segment_urls_for_dl[@]} - successful_dl)) segment(s) failed. Log: $parallel_joblog"; return 1; fi

  print_info "  ${GREEN}✓ Segments downloaded.${NC}"
  print_info "  Assembling video: $(basename "$output_video_path")"
  local ffmpeg_log="${temp_dir}/ffmpeg.log"
  if (cd "$temp_dir" && "$_FFMPEG" -y -nostdin -f concat -safe 0 -i "$(basename "$segment_list_file")" \
    -metadata "title=${episode_title}" \
    -metadata "track=${episode_number}" \
    -c copy "$output_video_path" >"$ffmpeg_log" 2>&1); then
    print_info "  ${GREEN}✓ Video assembled.${NC}"
  else
    print_warn "  ffmpeg assembly failed. Log: $ffmpeg_log"; cat "$ffmpeg_log" >&2; rm -f "$output_video_path"; return 1
  fi
  return 0
}

#
# Orchestrates the download of a single episode, handling both M3U8 and direct files.
# $1: JSON object with info for the episode to download.
# $2: JSON object with stream details (URLs, etc.).
#
download_episode() {
  local ep_info_json="$1" stream_details_json="$2"
  local ep_num title video_url is_m3u8 subtitles_json referer_url anime_dir padded_ep_num
  local output_filename_base output_video_path temp_episode_dir success=false

  ep_num=$("$_JQ" -r '.ep_num // empty' <<<"$ep_info_json")
  title=$("$_JQ" -r '.title // "Episode $ep_num"' <<<"$ep_info_json"); title=$(sanitize_filename "$title")

  video_url=$("$_JQ" -r '.video_url // empty' <<<"$stream_details_json")
  is_m3u8=$("$_JQ" -r '.is_m3u8 // false' <<<"$stream_details_json")
  subtitles_json=$("$_JQ" -c '.subtitles // []' <<<"$stream_details_json")
  referer_url=$("$_JQ" -r '.referer_url // empty' <<<"$stream_details_json")

  anime_dir="${_VIDEO_DIR_PATH}/${_ANIME_TITLE}"; mkdir -p "$anime_dir"

  local total_eps_for_padding; total_eps_for_padding=$(echo "$all_episodes_json_array_for_padding" | "$_JQ" -r '. | length')
  if [[ "$total_eps_for_padding" -gt 999 && ${#ep_num} -lt 4 ]]; then padded_ep_num=$(printf "%04d" "$ep_num")
  elif [[ "$total_eps_for_padding" -gt 99 && ${#ep_num} -lt 3 ]]; then padded_ep_num=$(printf "%03d" "$ep_num")
  elif [[ "$total_eps_for_padding" -gt 9 && ${#ep_num} -lt 2 ]]; then padded_ep_num=$(printf "%02d" "$ep_num")
  else padded_ep_num="$ep_num"; fi
  output_filename_base="${anime_dir}/Episode_${padded_ep_num}_${title}"
  output_video_path="${output_filename_base}.mp4"

  if [[ -f "$output_video_path" ]]; then print_info "${GREEN}✓ Ep ${ep_num} already exists. Skipping.${NC}"; return 0; fi
  print_info "Processing Episode ${BOLD}$ep_num${NC}: ${BOLD}$title${NC}"
  if [[ "$_LIST_LINKS_ONLY" == true ]]; then
    echo "Anime: $_ANIME_TITLE"; echo "Episode $ep_num: $title"; echo "  Video URL (M3U8: $is_m3u8): $video_url"
    if echo "$subtitles_json" | "$_JQ" -e '. | type=="array" and length > 0' >/dev/null; then
      echo "$subtitles_json" | "$_JQ" -r '.[] | "  Subtitle (\(.lang // "N/A")): \(.url // "N/A")"'
    fi
    return 0
  fi

  mkdir -p "$_TEMP_DIR_PARENT"
  temp_episode_dir=$("$_MKTEMP" -d "${_TEMP_DIR_PARENT}/aniwatch_dl_${_ANIME_ID}_ep${ep_num}_XXXXXX")
  if [[ -z "$temp_episode_dir" || ! -d "$temp_episode_dir" ]]; then print_error "Failed to create temp dir for ep $ep_num."; return 1; fi
  _temp_dirs_to_clean+=("$temp_episode_dir")

  # If the API says it's not an M3U8, but the URL says otherwise, trust the URL.
  if [[ "$is_m3u8" != "true" && "$video_url" == *.m3u8* ]]; then
    print_warn "  API reported non-M3U8, but URL suggests otherwise. Treating as M3U8."
    is_m3u8="true"
  fi

  if [[ "$is_m3u8" == "true" ]]; then
    if download_and_assemble_m3u8 "$video_url" "$output_video_path" "$temp_episode_dir" "$referer_url" "$title" "$ep_num"; then success=true; fi
  else
    print_info "  Downloading direct video file..."
    if download_file "$video_url" "$output_video_path" "$referer_url"; then success=true; fi
  fi

  if [[ "$success" == true ]]; then
    print_info "${GREEN}✓ Downloaded Ep ${ep_num} to $(basename "$output_video_path")${NC}"
    if [[ "$_SUBTITLE_LANGS_PREF" != "none" && -n "$subtitles_json" && "$subtitles_json" != "[]" ]]; then
      local subs_to_dl="[]"
      if [[ "$_SUBTITLE_LANGS_PREF" == "all" ]]; then
        subs_to_dl="$subtitles_json"
      elif [[ "$_SUBTITLE_LANGS_PREF" == "default" ]]; then
        local default_sub; default_sub=$("$_JQ" -c '([.[] | select(.lang | test("english"; "i"))] | .[0]) // .[0]' <<<"$subtitles_json")
        if [[ -n "$default_sub" && "$default_sub" != "null" ]]; then subs_to_dl="[$default_sub]"; fi
      else
        local temp_subs="[]"; local wanted_langs; IFS=',' read -ra wanted_langs <<< "$_SUBTITLE_LANGS_PREF"
        for lang in "${wanted_langs[@]}"; do
          local found_sub; found_sub=$("$_JQ" -c --arg l "$lang" '([.[] | select(.lang | test($l; "i"))] | .[0])' <<<"$subtitles_json")
          if [[ -n "$found_sub" && "$found_sub" != "null" ]]; then temp_subs=$("$_JQ" -c '. + [$found_sub]' <<<"$temp_subs"); fi
        done
        subs_to_dl=$("$_JQ" -c 'unique_by(.url)' <<<"$temp_subs")
      fi

      local num_subs_to_dl
      num_subs_to_dl=$(echo "$subs_to_dl" | "$_JQ" -r 'length // 0')
      if [[ "$num_subs_to_dl" -gt 0 ]]; then
        print_info "  Downloading $num_subs_to_dl subtitle track(s)..."
        while IFS= read -r sub_obj; do
          local sub_url sub_lang sub_filename
          sub_url=$(echo "$sub_obj" | "$_JQ" -r '.url')
          sub_lang=$(echo "$sub_obj" | "$_JQ" -r '.lang // "sub"')
          sub_filename="${output_filename_base}.${sub_lang}.vtt"
          print_info "    Downloading: $sub_lang"
          if ! download_file "$sub_url" "$sub_filename" "$referer_url"; then
            print_warn "    Failed to download subtitle: $sub_lang"
          fi
        done < <(echo "$subs_to_dl" | "$_JQ" -c '.[]')
      fi
    fi
  else
    print_warn "Failed to download video for Ep $ep_num."
    rm -f "$output_video_path"
  fi
  [[ "$success" == true ]] && return 0 || return 1
}

#
# Main function to orchestrate the entire download process.
#
main() {
  initialize_api_url
  echo -e "\n${PURPLE}========================================${NC}"
  echo -e "${BOLD}${CYAN}    AniWatch API Anime Downloader     ${NC}"
  echo -e "${PURPLE}========================================${NC}\n"
  parse_args "$@"
  check_deps
  mkdir -p "$_VIDEO_DIR_PATH" "$_TEMP_DIR_PARENT"

  echo -e "\n${CYAN}--- Anime Selection ---${NC}"
  if [[ -n "${_ANIME_ID_ARG:-}" ]]; then
    _ANIME_ID="$_ANIME_ID_ARG"
    fetch_anime_title_by_id "$_ANIME_ID"
  elif [[ -n "${_ANIME_SEARCH_NAME:-}" ]]; then
    search_and_select_anime "$_ANIME_SEARCH_NAME"
  else
    print_error "Should be caught by parse_args, but no anime was specified."
  fi

  echo -e "\n${CYAN}--- Episode Information ---${NC}"
  local all_episodes_json
  all_episodes_json=$(get_episode_info_list "$_ANIME_ID")
  if [[ $(echo "$all_episodes_json" | "$_JQ" -r 'length') -eq 0 ]]; then
    print_info "No episodes found for ${_ANIME_TITLE}. Exiting."; exit 0
  fi

  local target_episodes_json
  if [[ -z "$_EPISODE_SELECTION" ]]; then
    print_info "Available episodes for ${BOLD}$_ANIME_TITLE${NC}:"
    echo "$all_episodes_json" | "$_JQ" -r '.[] | .ep_num + " " + (.title // ("Episode " + .ep_num))' | awk '{ printf "  [%3s] %s\n", $1, substr($0, index($0,$2)) }' >&2
    local user_selection
    read -r -p "$(echo -e "${YELLOW}▶ Enter episode selection (e.g., 1, 3-5, *, L2):${NC} ")" user_selection
    if [[ -z "$user_selection" ]]; then print_error "No episode selection provided."; fi
    _EPISODE_SELECTION="$user_selection"
  fi
  target_episodes_json=$(parse_episode_selection "$_EPISODE_SELECTION" "$all_episodes_json")
  if [[ $(echo "$target_episodes_json" | "$_JQ" -r 'length') -eq 0 ]]; then
    print_info "No episodes selected based on input. Exiting."; exit 0
  fi

  echo -e "\n${CYAN}--- Starting Downloads ---${NC}"
  local success_count=0 failure_count=0 current_ep_idx=0

  local -a episodes_to_process
  mapfile -t episodes_to_process < <(echo "$target_episodes_json" | "$_JQ" -c '.[]')
  local total_sel_eps=${#episodes_to_process[@]}

  for ep_to_dl_json in "${episodes_to_process[@]}"; do
    current_ep_idx=$((current_ep_idx + 1))
    if [[ -z "$ep_to_dl_json" ]]; then continue; fi

    local ep_num_log stream_id_ep
    ep_num_log=$("$_JQ" -r '.ep_num' <<<"$ep_to_dl_json")
    stream_id_ep=$("$_JQ" -r '.stream_id' <<<"$ep_to_dl_json")

    local title; title=$("$_JQ" -r '.title // "Episode $ep_num_log"' <<<"$ep_to_dl_json"); title=$(sanitize_filename "$title")
    local padded_ep_num
    local total_eps_for_padding; total_eps_for_padding=$(echo "$all_episodes_json_array_for_padding" | "$_JQ" -r '. | length')
    if [[ "$total_eps_for_padding" -gt 999 && ${#ep_num_log} -lt 4 ]]; then padded_ep_num=$(printf "%04d" "$ep_num_log")
    elif [[ "$total_eps_for_padding" -gt 99 && ${#ep_num_log} -lt 3 ]]; then padded_ep_num=$(printf "%03d" "$ep_num_log")
    elif [[ "$total_eps_for_padding" -gt 9 && ${#ep_num_log} -lt 2 ]]; then padded_ep_num=$(printf "%02d" "$ep_num_log")
    else padded_ep_num="$ep_num_log"; fi

    local anime_dir="${_VIDEO_DIR_PATH}/${_ANIME_TITLE}"
    local output_video_path="${anime_dir}/Episode_${padded_ep_num}_${title}.mp4"

    echo -e "\n${PURPLE}>>> Processing Episode ${ep_num_log} (${current_ep_idx}/${total_sel_eps}) <<<${NC}"

    if [[ -f "$output_video_path" ]]; then
      print_info "${GREEN}✓ Ep ${ep_num_log} already exists. Skipping.${NC}"
      success_count=$((success_count + 1))
      continue
    fi

    local stream_details
    stream_details=$(get_stream_details "$stream_id_ep" "$_AUDIO_TYPE" "$_SERVER_KEYWORD" "$ep_num_log" || true)
    if [[ -z "$stream_details" ]]; then
        print_warn "Could not get stream details for Ep $ep_num_log. Skipping."
        failure_count=$((failure_count + 1)); continue
    fi

    if download_episode "$ep_to_dl_json" "$stream_details"; then
      success_count=$((success_count + 1))
    else
      failure_count=$((failure_count + 1))
    fi
  done

  echo -e "\n${PURPLE}========================================${NC}"
  echo -e "${BOLD}${CYAN}         Download Summary             ${NC}"
  echo -e "${PURPLE}========================================${NC}"
  print_info "Total episodes planned:   $total_sel_eps"
  [[ "$success_count" -gt 0 ]] && print_info "${GREEN}Successfully acquired:  $success_count episode(s)${NC}"
  [[ "$failure_count" -gt 0 ]] && print_warn "${RED}Failed to download:     $failure_count episode(s)${NC}"
  echo -e "${PURPLE}========================================${NC}\n"
  if [[ "$failure_count" -gt 0 ]]; then exit 1; fi
  exit 0
}


if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
