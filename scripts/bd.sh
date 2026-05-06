#!/bin/bash

# bd - 蓝光/普通视频截图和信息提取工具（optipng版 截图不删除）
# 用法: bd <路径> [--count <数量>] [--grid ROWSxCOLS] [--lang LANGUAGE] [--info]
set +e

# ===================== 日志配置 =====================
LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/bd-$(date +%Y%m%d-%H%M).log"
> "$LOG_FILE"

log_debug() {
    echo "【调试】$(date +"%Y-%m-%d %H:%M:%S") - $1" >> "$LOG_FILE"
}

log_error() {
    echo "【错误】$(date +"%Y-%m-%d %H:%M:%S") - $1" >> "$LOG_FILE"
    echo "错误: $1"
}

# ===================== 默认配置 =====================
COUNT=3
TARGET_DIR=""
MOUNT_POINT="/tmp/bd_mount"
GRID_LAYOUT=""
LANGUAGE="chinese"
OUTPUT_DIR=""
SHOW_INFO=false
MAX_PARALLEL=1
SKIP_DEP_CHECK=false

# BDInfo 配置
BDINFO_URL_X64="https://github.com/dotnetcorecorner/BDInfo/releases/download/linux-2.0.6/bdinfo_linux_v2.0.6.zip"
BDINFO_URL_ARM64="https://github.com/Kuanghom/BDInfo/releases/download/arm64-2.0.6/bdinfo_linux_arm64_v2.0.6.zip"
INSTALL_DIR="/usr/local/bin"
TEMPDIR=$(mktemp -d)

# 临时文件
touch .image_url.txt
chmod 666 .image_url.txt
chmod 777 $TEMPDIR

# ===================== 解析参数 =====================
while [[ $# -gt 0 ]]; do
    case $1 in
        --count)
            COUNT="$2"
            shift 2
            ;;
        --grid)
            GRID_LAYOUT="$2"
            shift 2
            ;;
        --lang)
            LANGUAGE="$2"
            shift 2
            ;;
        --info)
            SHOW_INFO=true
            shift
            ;;
        *)
            if [[ -z "$TARGET_DIR" ]]; then
                TARGET_DIR="${1//\'/}"
                # 固定截图根目录 = /home/screenshot
                USER_SCREENSHOT_DIR="/home/screenshot"
                mkdir -p "$USER_SCREENSHOT_DIR"
                chmod 777 "$USER_SCREENSHOT_DIR"
                
                if [[ -f "$TARGET_DIR" ]]; then
                    SUBDIR_NAME=$(basename "$TARGET_DIR" | sed 's/[^a-zA-Z0-9._-]/_/g')
                else
                    SUBDIR_NAME=$(basename "$TARGET_DIR" | sed 's/[^a-zA-Z0-9._-]/_/g')
                fi
                
                OUTPUT_DIR="${USER_SCREENSHOT_DIR}/${SUBDIR_NAME}"
                mkdir -p "$OUTPUT_DIR"
                chmod 777 "$OUTPUT_DIR"
                log_debug "【调试】输出目录: $OUTPUT_DIR" >&2
            else
                echo "错误: 多余的参数 $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# 目录可写检查
if [[ ! -w "$OUTPUT_DIR" ]]; then
    echo "错误: 输出目录不可写 - $OUTPUT_DIR" >&2
    sudo chmod 777 "$OUTPUT_DIR"
    if [[ ! -w "$OUTPUT_DIR" ]]; then
        echo "修复失败，请手动创建: mkdir -p $OUTPUT_DIR && chmod 777 $OUTPUT_DIR" >&2
        exit 1
    fi
fi

mkdir -p "$MOUNT_POINT"
chmod 777 "$MOUNT_POINT"

# ===================== 安装依赖（替换为 optipng） =====================
install_dependencies() {
    if [[ "$SKIP_DEP_CHECK" == true ]]; then
        echo "跳过依赖检查..." >&2
        return 0
    fi
    local missing=()
    # 移除 pngquant，添加 optipng
    for cmd in ffmpeg curl jq optipng mediainfo montage; do
        if ! command -v $cmd &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if command -v apt &>/dev/null; then
        if ! dpkg -l libicu-dev &>/dev/null; then
            missing+=("libicu-dev")
        fi
    elif command -v yum &>/dev/null; then
        if ! rpm -q libicu &>/dev/null; then
            missing+=("libicu" "libicu-devel")
        fi
    fi

    local imagemagick_pkg=""
    if command -v apt &>/dev/null; then
        imagemagick_pkg="imagemagick"
    elif command -v yum &>/dev/null; then
        imagemagick_pkg="ImageMagick"
    fi

    if ! command -v montage &>/dev/null && [ -n "$imagemagick_pkg" ]; then
        missing+=("$imagemagick_pkg")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo "正在安装依赖: ${missing[*]}" >&2
        if command -v apt &>/dev/null; then
            sudo apt update && sudo apt install -y "${missing[@]}"
        elif command -v yum &>/dev/null; then
            sudo yum install -y "${missing[@]}"
        else
            echo "请手动安装依赖: ${missing[*]}" >&2
            exit 1
        fi
    fi
}

# ===================== BDInfo 安装 =====================
install_bdinfo() {
    if ! command -v BDInfo &>/dev/null; then
        local arch=$(uname -m)
        local bdinfo_url=""
        
        if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
            echo "检测到ARM64架构，正在安装BDInfo..." >&2
            bdinfo_url="$BDINFO_URL_ARM64"
        else
            echo "检测到x86_64架构，正在安装BDInfo..." >&2
            bdinfo_url="$BDINFO_URL_X64"
        fi
        
        local mirrors=(
            "$bdinfo_url"
            "https://ghfast.top/$bdinfo_url"
        )
        
        for mirror in "${mirrors[@]}"; do
            if wget -q "$mirror" -O "$TEMPDIR/bdinfo.zip"; then
                unzip -q -o "$TEMPDIR/bdinfo.zip" -d "$TEMPDIR"
                chmod +x "$TEMPDIR"/BDInfo*
                sudo cp "$TEMPDIR"/BDInfo* "$INSTALL_DIR/"
                rm -rf "$TEMPDIR"
                echo "BDInfo 安装成功!" >&2
                return 0
            fi
        done
        echo "错误: 无法下载BDInfo" >&2
        exit 1
    fi
}

# ===================== 输入类型检测 =====================
get_input_type() {
    local input="$1"
    if [ -f "$input" ]; then
        local ext=$(echo "$input" | awk -F. '{if (NF>1) print tolower($NF)}')
        case "$ext" in
            mkv|mp4|avi|mov|flv|wmv|m4v|ts|m2ts) echo "video"; return 0;;
            iso) echo "iso"; return 0;;
        esac
        echo "bdfile"
    elif [ -d "$input" ]; then
        if [ -d "$input/BDMV" ]; then
            echo "bdmv"
        elif [ -d "$input/VIDEO_TS" ]; then
            echo "dvd"
        else
            local iso_file=$(find "$input" -maxdepth 1 -type f \( -iname "*.iso" \) | head -1)
            if [ -n "$iso_file" ]; then
                echo "iso"
            else
                local video_file=$(find "$input" -maxdepth 1 -type f \( -iname "*.mkv" -o -iname "*.mp4" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.ts" -o -iname "*.m2ts" \) | head -1)
                if [ -n "$video_file" ]; then
                    echo "video_file:$video_file"
                else
                    echo "错误: 无有效视频/BD文件" >&2
                    exit 1
                fi
            fi
        fi
    else
        echo "错误: 无效路径" >&2
        exit 1
    fi
}

# ===================== BDInfo 解析 =====================
parse_bdinfo() {
    awk '
    BEGIN {RS = "DISC INFO:"; max_size=0; best_section=""}
    NR>1 {
        section="DISC INFO:"$0; sub(/FILES:.*/,"",section)
        if(match(section,/Size:[[:space:]]+([0-9,]+)/)){
            size_str=substr(section,RSTART+5,RLENGTH-5); gsub(/,/,"",size_str); size=size_str+0
            if(size>max_size){max_size=size; best_section=section}
        }
    }
    END {
        if(best_section!=""){sub(/[[:space:]]+$/,"",best_section); print "↓#↓#↓#↓#↓#↓#↓#↓#↓#↓#↓ BDInfo 信息 ↓#↓#↓#↓#↓#↓#↓#↓#↓#↓#↓"; print best_section; print "↑#↑#↑#↑#↑#↑#↑#↑#↑#↑#↑ 分割线 ↑#↑#↑#↑#↑#↑#↑#↑#↑#↑#↑"}
        else{print "错误: 无有效PLAYLIST" > "/dev/stderr"; exit 1}
    }'
}

extract_bd_info() {
    local target="$1"
    install_bdinfo
    local bdinfo_file="$TEMPDIR/bdinfo_$$.txt"
    echo "正在提取BD信息..." >&2
    if BDInfo -p "$target" -o "$bdinfo_file"; then
        cp "$bdinfo_file" "${OUTPUT_DIR}/bdinfo.txt"
        parse_bdinfo < "$bdinfo_file"
        rm -f "$bdinfo_file"
    else
        echo "错误: BDInfo执行失败" >&2
        exit 1
    fi
}

extract_mediainfo() {
    local target="$1"
    local mediainfo_file="${OUTPUT_DIR}/mediainfo.txt"
    echo "正在提取MediaInfo信息..." >&2
    if mediainfo "$target" > "$mediainfo_file"; then
        echo "↓#↓#↓#↓#↓#↓#↓#↓#↓#↓#↓ MediaInfo 信息 ↓#↓#↓#↓#↓#↓#↓#↓#↓#↓#↓"
        mediainfo --Output=Human "$target"
        echo "↑#↑#↑#↑#↑#↑#↑#↑#↑#↑#↑ 分割线 ↑#↑#↑#↑#↑#↑#↑#↑#↑#↑#↑"
    else
        echo "错误: MediaInfo执行失败" >&2
        exit 1
    fi
}

# ===================== 清理（不删除截图） =====================
cleanup() {
    if mountpoint -q "$MOUNT_POINT"; then
        sudo umount "$MOUNT_POINT" 2>/dev/null || true
    fi
    rm -rf "$MOUNT_POINT" "$TEMPDIR"
    wait 2>/dev/null || true
}
trap cleanup EXIT

# ===================== 压缩图片：optipng -o7 =====================
compress_png() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        return 1
    fi

    log_debug "【调试】使用 optipng -o7 压缩: $file" >&2
    # 最高压缩，不修改位深度、像素、颜色模式
    optipng -o7 -quiet "$file"

    if [[ $? -eq 0 ]]; then
        log_debug "【调试】optipng 压缩完成: $file" >&2
    else
        log_error "【调试】optipng 压缩失败" >&2
    fi
    return 0
}

# ===================== 上传 =====================
upload_to_pixhost() {
    local file="$1"
    local max_size_mb=10
    local max_retry=3
    local retry_count=0

    while ((retry_count < max_retry)); do
        log_debug "【调试】上传图片: $file" >&2
        local response=$(curl -s -F "name=$(basename "$file")" -F "ajax=yes" -F "content_type=0" -F "file=@$file" "https://pixhost.to/new-upload/")
        if [ -z "$response" ]; then
            echo "上传失败(空响应)" >&2
        else
            local error=$(echo "$response" | jq -r '.error.description' 2>/dev/null)
            if [ "$error" != "null" ] && [ -n "$error" ]; then
                echo "上传失败($error)" >&2
            else
                local url=$(echo "$response" | jq -r '.show_url' | sed 's|\\||g;s|pixhost\.to/show|img2.pixhost.to/images|')
                echo "[img]$url[/img]"
                echo "$url" >> .image_url.txt
                log_debug "【调试】上传成功: $url" >&2
                return 0
            fi
        fi
        ((retry_count++))
        sleep 1
    done
    echo "上传失败: 超过最大重试次数" >&2
    return 1
}

# ===================== 时长/字幕 =====================
get_duration() {
    local input="$1"
    log_debug "【调试】获取时长: $input" >&2
    local duration=$(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null | awk '{print int($1)}')
    log_debug "【调试】视频时长: $duration 秒" >&2
    echo "$duration"
}

get_subtitle_index() {
    local input="$1"
    local language="$2"
    log_debug "【调试】查找字幕流: $language" >&2
    local subtitle_info=$(ffprobe -v error -select_streams s -show_entries stream=index,codec_name:stream_tags=language -of csv=p=0 "$input" 2>/dev/null)
    if [[ -z "$subtitle_info" ]]; then
        echo ""
        return
    fi

    declare -A lang_map=(
        ["chi"]="chinese" ["zho"]="chinese" ["zh"]="chinese"
        ["eng"]="english" ["en"]="english"
        ["jpn"]="japanese" ["ja"]="japanese"
        ["kor"]="korean" ["ko"]="korean"
    )
    local text_codecs="srt ass ssa subrip webvtt mov_text"
    local sub_idx=0

    while IFS= read -r line; do
        local index=$(echo "$line" | cut -d',' -f1)
        local codec=$(echo "$line" | cut -d',' -f2 | tr '[:upper:]' '[:lower:]')
        local lang=$(echo "$line" | cut -d',' -f3 | tr '[:upper:]' '[:lower:]')
        local sub_type="graphic"
        [[ " $text_codecs " == *" $codec "* ]] && sub_type="text"

        local normalized_lang="${lang_map[$lang]:-$lang}"
        local normalized_query="${lang_map[${language,,}]:-${language,,}}"
        if [[ "$normalized_lang" == *"$normalized_query"* ]]; then
            echo "$sub_idx,$sub_type"
            return
        fi
        ((sub_idx++))
    done <<< "$subtitle_info"
    echo ""
}

# ===================== 拼图 =====================
create_grid_with_ffmpeg() {
    local input_files=("$@")
    local grid_file="${OUTPUT_DIR}/$(date +%s)_grid.png"
    local valid_files=()

    for file in "${input_files[@]}"; do
        [[ -f "$file" && -s "$file" ]] && valid_files+=("$file")
    done

    if [[ ${#valid_files[@]} -eq 0 ]]; then
        echo "错误: 无有效截图" >&2
        return 1
    fi

    local rows=2 cols=2
    [[ -n "$GRID_LAYOUT" ]] && {
        rows=$(echo "$GRID_LAYOUT" | cut -d'x' -f1)
        cols=$(echo "$GRID_LAYOUT" | cut -d'x' -f2)
    }

    if [[ ${#valid_files[@]} -eq 1 ]]; then
        cp "${valid_files[0]}" "$grid_file"
    else
        local filter_complex=""
        for ((i=0; i<${#valid_files[@]}; i++)); do
            filter_complex+="[$i:v]scale=512:288:force_original_aspect_ratio=decrease,pad=512:288:(ow-iw)/2:(oh-ih)/2:white,setsar=1[v$i];"
        done

        local row_filters=""
        for ((row=0; row<rows; row++)); do
            local row_inputs=""
            for ((col=0; col<cols; col++)); do
                local idx=$((row * cols + col))
                [[ $idx -lt ${#valid_files[@]} ]] && row_inputs+="[v$idx]"
            done
            [[ -n "$row_inputs" ]] && filter_complex+="${row_inputs}hstack=inputs=$(echo "$row_inputs" | grep -o '\[' | wc -l)[row$row];"
        done

        local all_rows=""
        for ((row=0; row<rows; row++)); do
            [[ $((row * cols)) -lt ${#valid_files[@]} ]] && all_rows+="[row$row]"
        done
        filter_complex+="${all_rows}vstack=inputs=$(echo "$all_rows" | grep -o '\[' | wc -l)[out]"

        local input_args=()
        for file in "${valid_files[@]}"; do input_args+=("-i" "$file"); done

        ffmpeg "${input_args[@]}" -filter_complex "$filter_complex" -map "[out]" -y "$grid_file" 2>/dev/null
    fi

    [[ -f "$grid_file" && -s "$grid_file" ]] && upload_to_pixhost "$grid_file"
}

# ===================== 核心截图（不删除文件） =====================
process_video_file() {
    local video_file="$1"
    local TIMESTAMP=$(date +%s)
    local screenshot_files=()

    local duration=$(get_duration "$video_file")
    [[ ! "$duration" =~ ^[0-9]+$ ]] && { echo "错误: 时长无效" >&2; return 1; }

    local subtitle_info=$(get_subtitle_index "$video_file" "$LANGUAGE")
    local subtitle_index="" subtitle_type=""
    [[ -n "$subtitle_info" ]] && {
        subtitle_index=$(echo "$subtitle_info" | cut -d',' -f1)
        subtitle_type=$(echo "$subtitle_info" | cut -d',' -f2)
    }

    local margin=120
    local available_duration=$((duration - 2 * margin))
    (( duration == 0 || available_duration <= 0 )) && { echo "错误: 视频过短" >&2; return 1; }

    local total_frames=$COUNT rows=2 cols=2
    [[ -n "$GRID_LAYOUT" ]] && {
        rows=$(echo "$GRID_LAYOUT" | cut -d'x' -f1)
        cols=$(echo "$GRID_LAYOUT" | cut -d'x' -f2)
        total_frames=$((rows * cols))
    }
    local interval=$((available_duration / total_frames))
    local time_points=()
    for ((i=0; i<total_frames; i++)); do
        time_points+=($((margin + i * interval)))
    done

    echo "↓#↓#↓#↓#↓#↓#↓#↓#↓#↓#↓ 截图 ↓#↓#↓#↓#↓#↓#↓#↓#↓#↓#↓"
    local use_subtitle=false
    [[ -n "$subtitle_index" && "$subtitle_type" == "text" ]] && use_subtitle=true

    # 截图（保存后 压缩 + 上传，不删除）
    for ((i=0; i<total_frames; i++)); do
        local target_ts=${time_points[$i]}
        local seek_quick=$((target_ts - 1))
        local outfile="${OUTPUT_DIR}/${TIMESTAMP}_$(printf "%02d" $((i+1))).png"

        local ffmpeg_cmd=(
            ffmpeg -ss "$seek_quick" -i "$video_file" -ss 1
            -loglevel error -an -vframes 1 -c:v png -compression_level 3 -y
        )

        if [[ "$use_subtitle" == true ]]; then
            local escaped_file="${video_file//\\/\\\\}"
            escaped_file="${escaped_file//:/\\:}"
            escaped_file="${escaped_file//\'/\\\'}"
            [[ -n "$GRID_LAYOUT" ]] && ffmpeg_cmd+=(-vf "subtitles='$escaped_file':si=$subtitle_index,scale=512:-1") \
                                   || ffmpeg_cmd+=(-vf "subtitles='$escaped_file':si=$subtitle_index")
        else
            [[ -n "$GRID_LAYOUT" ]] && ffmpeg_cmd+=(-vf "scale=512:-1")
        fi
        ffmpeg_cmd+=("$outfile")

        "${ffmpeg_cmd[@]}" 2>/dev/null

        if [[ -f "$outfile" && -s "$outfile" ]]; then
            screenshot_files+=("$outfile")
            compress_png "$outfile"
            echo "截图 $((i+1)) 完成：$target_ts 秒 → $outfile"
        else
            echo "截图 $((i+1)) 失败" >&2
        fi
    done

    # 拼图 / 上传
    if [[ -n "$GRID_LAYOUT" ]]; then
        create_grid_with_ffmpeg "${screenshot_files[@]}"
    else
        for file in "${screenshot_files[@]}"; do
            [[ -f "$file" ]] && upload_to_pixhost "$file"
        done
    fi
}

# ===================== BDMV / ISO / DVD =====================
process_bdmv() {
    local bdmv_dir="$1"
    local stream_dir="$bdmv_dir/BDMV/STREAM"
    [[ ! -d "$stream_dir" ]] && { echo "错误: 无效BDMV" >&2; return 1; }
    local largest_file=$(find "$stream_dir" -iname "*.m2ts" -type f | xargs du -b | sort -nr | head -n1 | cut -f2)
    [[ -z "$largest_file" ]] && { echo "错误: 无m2ts" >&2; return 1; }
    echo "使用文件: $(basename "$largest_file")"
    [[ "$SHOW_INFO" == true ]] && { extract_bd_info "$bdmv_dir"; echo ""; }
    process_video_file "$largest_file"
}

process_iso() {
    local iso_file="$1"
    sudo mount -o loop "$iso_file" "$MOUNT_POINT" 2>/dev/null || { echo "挂载ISO失败" >&2; return 1; }
    if [[ -d "$MOUNT_POINT/BDMV" ]]; then
        process_bdmv "$MOUNT_POINT"
    elif [[ -d "$MOUNT_POINT/VIDEO_TS" ]]; then
        process_dvd "$MOUNT_POINT"
    else
        echo "无法识别ISO" >&2
        sudo umount "$MOUNT_POINT"
        return 1
    fi
    sudo umount "$MOUNT_POINT"
}

process_dvd() {
    local dvd_dir="$1"
    local video_ts_dir="$dvd_dir/VIDEO_TS"
    [[ ! -d "$video_ts_dir" ]] && { echo "错误: 无效DVD" >&2; return 1; }
    local largest_file=$(find "$video_ts_dir" -name "*.VOB" | xargs du -b | sort -nr | head -n1 | cut -f2)
    [[ -z "$largest_file" ]] && { echo "错误: 无VOB" >&2; return 1; }
    process_video_file "$largest_file"
}

process_regular_video() {
    local video_file="$1"
    [[ "$SHOW_INFO" == true ]] && { extract_mediainfo "$video_file"; echo ""; }
    process_video_file "$video_file"
}

# ===================== 主函数 =====================
main() {
    install_dependencies
    [[ -z "$TARGET_DIR" ]] && { echo "用法: $0 <路径>" >&2; exit 1; }
    local input_type=$(get_input_type "$TARGET_DIR")
    case "$input_type" in
        bdmv) process_bdmv "$TARGET_DIR" ;;
        iso)
            if [[ -f "$TARGET_DIR" ]]; then
                process_iso "$TARGET_DIR"
            else
                local iso_file=$(find "$TARGET_DIR" -maxdepth 1 -type f -iname "*.iso" | head -n1)
                [[ -n "$iso_file" ]] && process_iso "$iso_file" || { echo "无ISO" >&2; exit 1; }
            fi ;;
        dvd) process_dvd "$TARGET_DIR" ;;
        video) process_regular_video "$TARGET_DIR" ;;
        video_file:*) process_regular_video "${input_type#video_file:}" ;;
        bdfile) process_video_file "$TARGET_DIR" ;;
        *) echo "错误: 不支持类型" >&2; exit 1 ;;
    esac

    echo -e "\n↓#↓#↓#↓#↓#↓#↓#↓#↓#↓#↓ 完成 ↓#↓#↓#↓#↓#↓#↓#↓#↓#↓#↓"
    if [[ -s .image_url.txt ]]; then
        echo -e "\n---------------- 图片地址 ----------------\n"
        cat .image_url.txt
        rm -f .image_url.txt
    fi
    echo -e "\n截图已保存到：$OUTPUT_DIR"
}

main "$@"
