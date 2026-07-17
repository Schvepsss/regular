#!/bin/bash
# regular — autopublish.sh
# Копирует новые черновики из blog-drafts/ в Regular_site_publish/ и пушит на GitHub Pages.
# Запускается LaunchAgent по Пн/Чт в 10:00.

REPO_DIR="/Users/schvepsss/Documents/GitHub/regular"
DRAFTS_DIR="/Users/schvepsss/Documents/Claude/Projects/Regular/Marketing/Blog + site/blog-drafts"
PUBLISH_MIRROR="/Users/schvepsss/Documents/Claude/Projects/Regular/Marketing/Blog + site/Regular_site_publish"
TOKEN_FILE="/Users/schvepsss/Documents/Claude/Projects/Regular/.github_token"
LOG="/Users/schvepsss/Documents/Claude/Projects/Regular/autopublish.log"
GITHUB_USER="Schvepsss"
REPO_NAME="regular"
BLOG_HTML="$REPO_DIR/regular_blog.html"

log() { echo "[$(date '+%Y-%m-%d %H:%M')] $*" | tee -a "$LOG"; }
log "=== Auto-publish started ==="

# Проверки
if [ ! -f "$TOKEN_FILE" ]; then log "ERROR: token file not found at $TOKEN_FILE"; exit 1; fi
TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE")
TODAY=$(date '+%b %Y')  # "Jul 2026"
NEW_FILES=()
NEW_URLS=()

# ---- 1. Копируем blog-черновики ----
for f in "$DRAFTS_DIR"/*.html; do
    [ -f "$f" ] || continue
    base=$(basename "$f")

    # Пропускаем файлы с незаполненными плейсхолдерами
    if grep -q "{{" "$f" 2>/dev/null; then
        log "SKIP (placeholders): $base"
        continue
    fi

    if [[ "$base" == blog_* ]]; then
        target="$base"
    else
        target="blog_$base"
    fi

    if [ ! -f "$REPO_DIR/$target" ]; then
        cp "$f" "$REPO_DIR/$target"
        cp "$f" "$PUBLISH_MIRROR/$target"
        NEW_FILES+=("$target")
        slug="${target%.html}"
        NEW_URLS+=("https://regular.care/$slug")
        log "Copied blog: $target"

        # Инжектим карточку в ARTICLES[] в regular_blog.html
        title=$(grep -m1 'property="og:title"' "$f" | grep -o 'content="[^"]*"' | sed 's/content="//;s/"$//')
        desc=$(grep -m1 'property="og:description"' "$f" | grep -o 'content="[^"]*"' | sed 's/content="//;s/"$//')
        tag=$(grep -o '<span class="tag">[^<]*</span>' "$f" | head -1 | sed 's/<[^>]*>//g;s/ \/.*//')
        [ -z "$tag" ] && tag="Reconnecting"
        group="Reconnecting"
        [[ "$tag" == *"Science"* || "$tag" == *"decoded"* || "$tag" == *"Neuroscience"* || "$tag" == *"Research"* ]] && group="Science"
        [[ "$tag" == *"Intimacy"* || "$tag" == *"sex"* || "$tag" == *"Sex"* ]] && group="Intimacy"
        [[ "$tag" == *"Tool"* || "$tag" == *"App"* ]] && group="Tools"

        python3 - "$BLOG_HTML" "$slug" "$group" "$tag" "$title" "$desc" << 'PYEOF'
import sys
blog_file, slug, group, tag, title, desc = sys.argv[1:7]
with open(blog_file, 'r', encoding='utf-8') as fh:
    html = fh.read()
marker = 'var ARTICLES=['
entry = f"\n    {{slug:'{slug}',title:'{title}',desc:'{desc}',group:'{group}',tag:'{tag}',meta:'New'}},"
if marker in html:
    html = html.replace(marker, marker + entry, 1)
    with open(blog_file, 'w', encoding='utf-8') as fh:
        fh.write(html)
    print(f"  ARTICLES[] updated with: {slug}")
else:
    print(f"  WARNING: ARTICLES marker not found in regular_blog.html")
PYEOF
    fi
done

# ---- 2. Копируем news-черновики + инжектим в regular_blog.html ----
BLOG_HTML="$REPO_DIR/regular_blog.html"

for f in "$DRAFTS_DIR/news"/*.html; do
    [ -f "$f" ] || continue
    base=$(basename "$f")

    if grep -q "{{" "$f" 2>/dev/null; then
        log "SKIP (placeholders): $base"
        continue
    fi

    if [ ! -f "$REPO_DIR/$base" ]; then
        cp "$f" "$REPO_DIR/$base"
        cp "$f" "$PUBLISH_MIRROR/$base"
        NEW_FILES+=("$base")
        slug="${base%.html}"
        NEW_URLS+=("https://regular.care/$slug")
        log "Copied news: $base"

        # Извлекаем метаданные
        title=$(grep -m1 'property="og:title"' "$f" | grep -o 'content="[^"]*"' | sed 's/content="//;s/"$//')
        desc=$(grep -m1 'property="og:description"' "$f" | grep -o 'content="[^"]*"' | sed 's/content="//;s/"$//')
        category=$(grep -o '<span class="tag">[^<]*</span>' "$f" | head -1 | sed 's/<[^>]*>//g;s/ \/.*//')
        [ -z "$category" ] && category="Research"

        # Добавляем в newslist через Python (безопаснее чем sed для HTML)
        python3 - "$BLOG_HTML" "$slug" "$TODAY" "$category" "$title" "$desc" << 'PYEOF'
import sys

blog_file, slug, today, category, title, desc = sys.argv[1:7]

with open(blog_file, 'r', encoding='utf-8') as fh:
    html = fh.read()

marker = '<div class="newslist">'
newsitem = (
    f'\n      <a class="newsitem" href="{slug}">\n'
    f'        <span class="nd">{today} · {category}</span>\n'
    f'        <span><h4>{title}</h4><p>{desc}</p></span>\n'
    f'      </a>'
)

if marker in html:
    html = html.replace(marker, marker + newsitem, 1)
    with open(blog_file, 'w', encoding='utf-8') as fh:
        fh.write(html)
    print(f"  Blog listing updated with: {slug}")
else:
    print(f"  WARNING: newslist marker not found in regular_blog.html")
PYEOF
    fi
done

if [ ${#NEW_FILES[@]} -eq 0 ]; then
    log "No new files. Nothing to publish."
    exit 0
fi

# ---- 3. Обновляем sitemap.xml ----
SITEMAP="$REPO_DIR/sitemap.xml"
for url in "${NEW_URLS[@]}"; do
    if ! grep -qF "$url" "$SITEMAP"; then
        slug_only=$(echo "$url" | sed 's|https://regular.care/||')
        priority="0.7"
        [[ "$slug_only" == news_* ]] && priority="0.6"
        sed -i '' "s|</urlset>|  <url><loc>${url}</loc><changefreq>weekly</changefreq><priority>${priority}</priority></url>\n</urlset>|" "$SITEMAP"
        log "Sitemap: added $url"
    fi
done

# ---- 4. Синхронизируем blog-listing и sitemap в git-репо ----
cp "$PUBLISH_MIRROR/regular_blog.html" "$REPO_DIR/regular_blog.html"
cp "$PUBLISH_MIRROR/sitemap.xml" "$REPO_DIR/sitemap.xml"

# ---- 5. Git commit + push ----
cd "$REPO_DIR" || { log "ERROR: cannot cd to $REPO_DIR"; exit 1; }

# Сначала коммитим локальные изменения, потом тянем remote (иначе pull падает на unstaged changes)
git add .
git commit -m "Auto-publish: ${#NEW_FILES[@]} articles [$(date '+%Y-%m-%d')]"
GIT_EDITOR=true git pull "https://${GITHUB_USER}:${TOKEN}@github.com/${GITHUB_USER}/${REPO_NAME}.git" main --no-rebase -X ours --no-edit 2>> "$LOG"
git push "https://${GITHUB_USER}:${TOKEN}@github.com/${GITHUB_USER}/${REPO_NAME}.git" main >> "$LOG" 2>&1

if [ $? -eq 0 ]; then
    log "SUCCESS: pushed ${#NEW_FILES[@]} files to GitHub Pages."
else
    log "ERROR: git push failed — check $LOG for details."
fi

log "=== Auto-publish done ==="
