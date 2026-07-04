#!/bin/sh
set -eu

config_path="/usr/share/nginx/html/debug-config.json"

if [ "${VIDEO_BENCH_DEBUG_MODE:-0}" = "1" ]; then
  video_url="${VIDEO_BENCH_DEBUG_VIDEO_URL:-/api/mounted-files/file/?path=airport_walk/airport_walk_normal.mov}"
  video_filename="${VIDEO_BENCH_DEBUG_VIDEO_FILENAME:-airport_walk_normal.mov}"
  csv_url="${VIDEO_BENCH_DEBUG_CSV_URL:-/api/mounted-files/file/?path=airport_walk/report_airport_walk_normal.mov.csv}"
  csv_filename="${VIDEO_BENCH_DEBUG_CSV_FILENAME:-report_airport_walk_normal.mov.csv}"
  impact_source_type="${VIDEO_BENCH_DEBUG_IMPACT_SOURCE_TYPE:-mounted}"
  impact_source_path="${VIDEO_BENCH_DEBUG_IMPACT_SOURCE_PATH:-airport_walk/airport_walk_normal.mov}"
  agent_control="${VIDEO_BENCH_AGENT_CONTROL:-true}"
  experimental="${VIDEO_BENCH_EXPERIMENTAL:-false}"
  cat > "$config_path" <<EOF
{"enabled":true,"agentControl":$agent_control,"videoUrl":"$video_url","videoFilename":"$video_filename","csvUrl":"$csv_url","csvFilename":"$csv_filename","impactSourceType":"$impact_source_type","impactSourcePath":"$impact_source_path","experimental":$experimental}
EOF
else
  printf '{"enabled":false}\n' > "$config_path"
fi
