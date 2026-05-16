#!/usr/bin/env bash
set -euo pipefail

base="${1:-}"
if [ -z "$base" ]; then
    script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
    if [ "$(basename -- "$script_dir")" = "windrose_plus_custom" ]; then
        base="$(CDPATH= cd -- "$script_dir/.." && pwd)"
    else
        base="$(pwd)"
    fi
fi
base="$(CDPATH= cd -- "$base" && pwd)"

custom="$base/windrose_plus_custom"
custom_tools="$custom/tools"
custom_bin="$custom_tools/bin"
custom_pwsh="$custom_tools/pwsh"
tools="$base/windrose_plus/tools"
bin="$tools/bin"
paks="$base/R5/Content/Paks"

mkdir -p "$custom" "$custom_bin" "$bin" "$paks"

write_harvest_config() {
    cat > "$base/windrose_plus.harvest.ini" <<'EOF'
; Quistify per-resource harvest overrides.
; Managed by windrose-quistify-overrides.sh and reapplied after AMP updates.
; Keep global harvest_yield at default/empty if we only want these resources boosted.
[Resources]
Wood = 2.0
Stone = 2.0
CopperOre = 2.0
Iron = 2.0
Hardwood = 2.0
Bark = 2.0
EOF
}

ensure_repak() {
    repak_url="https://github.com/trumank/repak/releases/download/v0.2.3/repak_cli-x86_64-unknown-linux-gnu.tar.xz"
    cached_repak="$custom_bin/repak.linux"
    live_repak="$bin/repak.linux"
    repak_exe="$bin/repak.exe"
    repak_win="$bin/repak.win.exe"

    if [ ! -x "$cached_repak" ]; then
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' RETURN
        echo "Downloading Linux repak 0.2.3..." >&2
        curl -fsSL "$repak_url" -o "$tmp/repak.tar.xz"
        tar -C "$tmp" -xf "$tmp/repak.tar.xz"
        candidate="$(find "$tmp" -type f -name repak | head -n 1)"
        if [ -z "$candidate" ]; then
            echo "Failed to find repak binary in $repak_url" >&2
            exit 1
        fi
        install -m 0755 "$candidate" "$cached_repak"
        rm -rf "$tmp"
        trap - RETURN
    fi

    install -m 0755 "$cached_repak" "$live_repak"

    if [ -f "$repak_exe" ] && ! head -n 1 "$repak_exe" 2>/dev/null | grep -q '^#!'; then
        if [ ! -f "$repak_win" ]; then
            mv "$repak_exe" "$repak_win"
        else
            rm -f "$repak_exe"
        fi
    fi

    cat > "$repak_exe" <<'EOF'
#!/bin/sh
set -eu
dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$dir/repak.linux" "$@"
EOF
    chmod 0755 "$repak_exe"
}

ensure_pwsh() {
    if command -v pwsh >/dev/null 2>&1; then
        command -v pwsh
        return
    fi

    if [ -x "$custom_pwsh/pwsh" ]; then
        printf '%s\n' "$custom_pwsh/pwsh"
        return
    fi

    pwsh_url="https://github.com/PowerShell/PowerShell/releases/download/v7.4.7/powershell-7.4.7-linux-x64.tar.gz"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    mkdir -p "$custom_pwsh"
    echo "Downloading portable PowerShell 7.4.7 for Windrose+ PAK builds..." >&2
    curl -fsSL "$pwsh_url" -o "$tmp/powershell.tar.gz"
    tar -C "$custom_pwsh" -xzf "$tmp/powershell.tar.gz"
    chmod 0755 "$custom_pwsh/pwsh"
    rm -rf "$tmp"
    trap - RETURN
    printf '%s\n' "$custom_pwsh/pwsh"
}

write_rough_hide_builder() {
    cat > "$custom/build_rough_hide_2x_pak.sh" <<'EOF'
#!/bin/sh
set -eu

base="${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
repak="$base/windrose_plus/tools/bin/repak.exe"
source_pak="$base/R5/Content/Paks/pakchunk0-WindowsServer.pak"
out_pak="$base/R5/Content/Paks/WindrosePlus_RoughHide_2x_P.pak"
item_id="DA_DID_Resource_Leather_T01"

command -v jq >/dev/null 2>&1 || { echo "jq is required to build rough-hide override PAK." >&2; exit 1; }

aes_key=$(
  sed -n 's/.*WindroseAesKey = "\(.*\)".*/\1/p' \
    "$base/windrose_plus/tools/lib/IniConfigParser.ps1" | head -n 1
)

if [ -z "$aes_key" ]; then
  echo "Failed to read Windrose AES key from Windrose+ tools." >&2
  exit 1
fi

if [ ! -x "$repak" ]; then
  echo "repak is not executable at $repak" >&2
  exit 1
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

tables='
R5/Plugins/R5BusinessRules/Content/LootTables/Mobs/Rss/DA_LT_Mob_AlphaWolf_Leather.json
R5/Plugins/R5BusinessRules/Content/LootTables/Mobs/Rss/DA_LT_Mob_Boar_Leather.json
R5/Plugins/R5BusinessRules/Content/LootTables/Mobs/Rss/DA_LT_Mob_BoarF_Leather.json
R5/Plugins/R5BusinessRules/Content/LootTables/Mobs/Rss/DA_LT_Mob_BoarMega_Leather.json
R5/Plugins/R5BusinessRules/Content/LootTables/Mobs/Rss/DA_LT_Mob_GoatF_Leather.json
R5/Plugins/R5BusinessRules/Content/LootTables/Mobs/Rss/DA_LT_Mob_GoatM_Leather.json
R5/Plugins/R5BusinessRules/Content/LootTables/Mobs/Rss/DA_LT_Mob_GoatMega_Leather.json
R5/Plugins/R5BusinessRules/Content/LootTables/Mobs/Rss/DA_LT_Mob_Wolf_Leather.json
'

changed=0
for table in $tables; do
  target="$stage/$table"
  mkdir -p "$(dirname -- "$target")"
  "$repak" --aes-key "$aes_key" get "$source_pak" "$table" > "$target"
  tmp="$target.tmp"
  jq --arg item "$item_id" '
    (.LootData[]? | select((.LootItem // "") | contains($item)) | .Min) *= 2
    | (.LootData[]? | select((.LootItem // "") | contains($item)) | .Max) *= 2
  ' "$target" > "$tmp"
  mv "$tmp" "$target"
  changed=$((changed + 1))
done

tmp_out="$out_pak.tmp"
rm -f "$tmp_out"
"$repak" pack "$stage" "$tmp_out" >/dev/null
mv "$tmp_out" "$out_pak"

echo "Built $out_pak with $changed rough-hide loot tables at 2x."
EOF
    chmod 0755 "$custom/build_rough_hide_2x_pak.sh"
}

write_ship_tokens_builder() {
    cat > "$custom/build_ship_faction_tokens_2x_pak.sh" <<'EOF'
#!/bin/sh
set -eu

base="${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
repak="$base/windrose_plus/tools/bin/repak.exe"
source_pak="$base/R5/Content/Paks/pakchunk0-WindowsServer.pak"
out_pak="$base/R5/Content/Paks/WindrosePlus_ShipFactionTokens_2x_P.pak"
item_regex="DA_DID_Reputation_BlackbeardSign_0[234]|DA_DID_Misc_Coin(Piastre_T02|Guinea_T03)"

command -v jq >/dev/null 2>&1 || { echo "jq is required to build ship token/coin override PAK." >&2; exit 1; }

aes_key=$(
  sed -n 's/.*WindroseAesKey = "\(.*\)".*/\1/p' \
    "$base/windrose_plus/tools/lib/IniConfigParser.ps1" | head -n 1
)

if [ -z "$aes_key" ]; then
  echo "Failed to read Windrose AES key from Windrose+ tools." >&2
  exit 1
fi

if [ ! -x "$repak" ]; then
  echo "repak is not executable at $repak" >&2
  exit 1
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
work="$stage/files"
list_file="$stage/ship_tables.txt"
mkdir -p "$work"

"$repak" --aes-key "$aes_key" list "$source_pak" | awk '
  /^R5\/Plugins\/R5BusinessRules\/Content\/LootTables\/Ships\/[^/]+\.json$/ { print; next }
  /^R5\/Plugins\/R5BusinessRules\/Content\/LootTables\/Ships\/Rss\/DA_LT_Ships_BlackbeardSign[0-9]+_.*\.json$/ { print; next }
' > "$list_file"

changed_tables=0
changed_entries=0
while IFS= read -r table; do
  [ -n "$table" ] || continue
  target="$work/$table"
  mkdir -p "$(dirname -- "$target")"
  "$repak" --aes-key "$aes_key" get "$source_pak" "$table" > "$target"

  entries=$(
    jq --arg re "$item_regex" \
      '[.LootData[]? | select((.LootItem // "") | test($re))] | length' \
      "$target"
  )

  if [ "$entries" -eq 0 ]; then
    rm -f "$target"
    continue
  fi

  tmp="$target.tmp"
  jq --arg re "$item_regex" '
    (.LootData[]? | select((.LootItem // "") | test($re)) | .Min) *= 2
    | (.LootData[]? | select((.LootItem // "") | test($re)) | .Max) *= 2
  ' "$target" > "$tmp"
  mv "$tmp" "$target"

  changed_tables=$((changed_tables + 1))
  changed_entries=$((changed_entries + entries))
done < "$list_file"

if [ "$changed_tables" -eq 0 ]; then
  echo "No ship faction token/coin loot entries matched; refusing to build empty PAK." >&2
  exit 1
fi

tmp_out="$out_pak.tmp"
rm -f "$tmp_out"
"$repak" pack "$work" "$tmp_out" >/dev/null
mv "$tmp_out" "$out_pak"

echo "Built $out_pak with $changed_entries ship faction token/coin entries across $changed_tables tables at 2x."
EOF
    chmod 0755 "$custom/build_ship_faction_tokens_2x_pak.sh"
}

write_coin_loot_builder() {
    cat > "$custom/build_coin_loot_2x_pak.sh" <<'EOF'
#!/bin/sh
set -eu

base="${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
repak="$base/windrose_plus/tools/bin/repak.exe"
source_pak="$base/R5/Content/Paks/pakchunk0-WindowsServer.pak"
out_pak="$base/R5/Content/Paks/WindrosePlus_CoinLoot_2x_P.pak"
item_regex="DA_DID_Misc_Coin(Piastre_T02|Guinea_T03)"

command -v jq >/dev/null 2>&1 || { echo "jq is required to build coin-loot override PAK." >&2; exit 1; }

aes_key=$(
  sed -n 's/.*WindroseAesKey = "\(.*\)".*/\1/p' \
    "$base/windrose_plus/tools/lib/IniConfigParser.ps1" | head -n 1
)

if [ -z "$aes_key" ]; then
  echo "Failed to read Windrose AES key from Windrose+ tools." >&2
  exit 1
fi

if [ ! -x "$repak" ]; then
  echo "repak is not executable at $repak" >&2
  exit 1
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
work="$stage/files"
list_file="$stage/coin_tables.txt"
mkdir -p "$work"

"$repak" --aes-key "$aes_key" list "$source_pak" | awk '
  /^R5\/Plugins\/R5BusinessRules\/Content\/LootTables\/Ships\// { next }
  /^R5\/Plugins\/R5BusinessRules\/Content\/LootTables\/.*\.json$/ { print }
' > "$list_file"

changed_tables=0
changed_entries=0
while IFS= read -r table; do
  [ -n "$table" ] || continue
  target="$work/$table"
  mkdir -p "$(dirname -- "$target")"
  "$repak" --aes-key "$aes_key" get "$source_pak" "$table" > "$target"

  entries=$(
    jq --arg re "$item_regex" \
      '[.LootData[]? | select((.LootItem // "") | test($re))] | length' \
      "$target"
  )

  if [ "$entries" -eq 0 ]; then
    rm -f "$target"
    continue
  fi

  tmp="$target.tmp"
  jq --arg re "$item_regex" '
    (.LootData[]? | select((.LootItem // "") | test($re)) | .Min) *= 2
    | (.LootData[]? | select((.LootItem // "") | test($re)) | .Max) *= 2
  ' "$target" > "$tmp"
  mv "$tmp" "$target"

  changed_tables=$((changed_tables + 1))
  changed_entries=$((changed_entries + entries))
done < "$list_file"

if [ "$changed_tables" -eq 0 ]; then
  echo "No Piastre/Guinea loot entries matched; refusing to build empty PAK." >&2
  exit 1
fi

tmp_out="$out_pak.tmp"
rm -f "$tmp_out"
"$repak" pack "$work" "$tmp_out" >/dev/null
mv "$tmp_out" "$out_pak"

echo "Built $out_pak with $changed_entries Piastre/Guinea loot entries across $changed_tables non-ship tables at 2x."
EOF
    chmod 0755 "$custom/build_coin_loot_2x_pak.sh"
}

write_lantern_runtime_builder() {
    cat > "$custom/build_lantern_runtime_2x_pak.sh" <<'EOF'
#!/bin/sh
set -eu

base="${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
repak="$base/windrose_plus/tools/bin/repak.exe"
source_pak="$base/R5/Content/Paks/pakchunk0-WindowsServer.pak"
out_pak="$base/R5/Content/Paks/WindrosePlus_LanternRuntime_2x_P.pak"
asset="R5/Plugins/R5BusinessRules/Content/InventoryItems/Consumables/Misc/DA_CID_Misc_Lantern_L1_T01.json"
counter_tag="Inventory.Item.Attribute.Counter"

command -v jq >/dev/null 2>&1 || { echo "jq is required to build lantern runtime override PAK." >&2; exit 1; }

aes_key=$(
  sed -n 's/.*WindroseAesKey = "\(.*\)".*/\1/p' \
    "$base/windrose_plus/tools/lib/IniConfigParser.ps1" | head -n 1
)

if [ -z "$aes_key" ]; then
  echo "Failed to read Windrose AES key from Windrose+ tools." >&2
  exit 1
fi

if [ ! -x "$repak" ]; then
  echo "repak is not executable at $repak" >&2
  exit 1
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

target="$stage/$asset"
mkdir -p "$(dirname -- "$target")"
"$repak" --aes-key "$aes_key" get "$source_pak" "$asset" > "$target"

old_max=$(
  jq -er --arg tag "$counter_tag" \
    'first(.InventoryItemGppData.Attributes[]? | select(.Tag.TagName == $tag) | .MaxValue)' \
    "$target"
) || {
  echo "Lantern counter MaxValue not found in $asset; refusing to build empty PAK." >&2
  exit 1
}

tmp="$target.tmp"
jq --arg tag "$counter_tag" '
  (.InventoryItemGppData.Attributes[]? | select(.Tag.TagName == $tag) | .MaxValue) *= 2
' "$target" > "$tmp"
mv "$tmp" "$target"

new_max=$(
  jq -er --arg tag "$counter_tag" \
    'first(.InventoryItemGppData.Attributes[]? | select(.Tag.TagName == $tag) | .MaxValue)' \
    "$target"
)

tmp_out="$out_pak.tmp"
rm -f "$tmp_out"
"$repak" pack "$stage" "$tmp_out" >/dev/null
mv "$tmp_out" "$out_pak"

echo "Built $out_pak with lantern runtime MaxValue $old_max -> $new_max."
EOF
    chmod 0755 "$custom/build_lantern_runtime_2x_pak.sh"
}

write_build_all() {
    cat > "$custom/build_all_quistify_overrides.sh" <<'EOF'
#!/bin/sh
set -eu

base="${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
exec "$base/windrose_plus_custom/windrose-quistify-overrides.sh" "$base"
EOF
    chmod 0755 "$custom/build_all_quistify_overrides.sh"
}

write_docs() {
    cat > "$custom/MODS.md" <<'EOF'
# Quistify Windrose Server Overrides

Managed by `windrose-quistify-overrides.sh`. AMP update fetches the script from the `dankmaster/amptemplates` fork and reapplies it after Windrose+ is refreshed.

Active server-side PAKs:

- `WindrosePlus_Multipliers_P.pak`: generated by Windrose+ from `windrose_plus.harvest.ini`. Current targeted 2x resources: wood, stone, copper ore, iron ore, hard wood, bark.
- `WindrosePlus_RoughHide_2x_P.pak`: custom server-side PAK that doubles rough hide (`DA_DID_Resource_Leather_T01`) from boar/sow, wolves, and goats.
- `WindrosePlus_ShipFactionTokens_2x_P.pak`: custom server-side PAK that doubles Blackbeard faction ship-token drops (`DA_DID_Reputation_BlackbeardSign_02/03/04`) and ship loot-table Piastre/Guinea coin drops.
- `WindrosePlus_CoinLoot_2x_P.pak`: custom server-side PAK that doubles non-ship Piastre/Guinea loot-table drops (`DA_DID_Misc_CoinPiastre_T02`, `DA_DID_Misc_CoinGuinea_T03`).
- `WindrosePlus_LanternRuntime_2x_P.pak`: custom server-side PAK that doubles lamp runtime by changing the lantern counter max value from 900 to 1800.

Manual rebuild:

```sh
bash windrose_plus_custom/windrose-quistify-overrides.sh /path/to/windrose/server
```

This does not require client-side mods. A running server normally needs a restart before newly built PAK files are loaded.
EOF
}

run_windroseplus_builder() {
    builder="$tools/WindrosePlus-BuildPak.ps1"
    if [ ! -f "$builder" ]; then
        echo "Windrose+ builder not found at $builder; skipping Windrose+ multiplier PAK." >&2
        return
    fi

    pwsh_bin="$(ensure_pwsh)"
    "$pwsh_bin" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$builder" -ServerDir "$base"
}

run_custom_builders() {
    "$custom/build_rough_hide_2x_pak.sh" "$base"
    "$custom/build_ship_faction_tokens_2x_pak.sh" "$base"
    "$custom/build_coin_loot_2x_pak.sh" "$base"
    "$custom/build_lantern_runtime_2x_pak.sh" "$base"
}

write_harvest_config
ensure_repak
write_rough_hide_builder
write_ship_tokens_builder
write_coin_loot_builder
write_lantern_runtime_builder
write_build_all
write_docs
run_windroseplus_builder
run_custom_builders

echo "Quistify Windrose overrides applied."
