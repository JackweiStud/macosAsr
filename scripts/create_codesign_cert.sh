#!/usr/bin/env bash
# 创建并导入本地代码签名证书「macosAsr Local」（Step 0）
# 用途：rebuild 后辅助功能授权不再因 ad-hoc cdhash 变化而失效
set -euo pipefail

NAME="macosAsr Local"
PASS="macosAsr"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "[cert] 清理旧证书（若存在）..."
while read -r hash; do
  security delete-certificate -Z "$hash" "$KEYCHAIN" 2>/dev/null || true
done < <(security find-certificate -c "$NAME" -a -Z 2>/dev/null | awk '/SHA-1/ {print $3}')

cat > "$WORKDIR/openssl.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $NAME

[v3_req]
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = critical, CA:TRUE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

echo "[cert] 生成密钥与证书..."
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$WORKDIR/key.pem" -out "$WORKDIR/cert.pem" \
  -config "$WORKDIR/openssl.cnf" -extensions v3_req 2>/dev/null

openssl pkcs12 -export -legacy \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
  -out "$WORKDIR/cert.p12" \
  -inkey "$WORKDIR/key.pem" -in "$WORKDIR/cert.pem" \
  -passout pass:"$PASS" -name "$NAME"

echo "[cert] 导入钥匙串 login..."
security import "$WORKDIR/cert.p12" \
  -k "$KEYCHAIN" \
  -P "$PASS" -A \
  -T /usr/bin/codesign -T /usr/bin/security 2>&1

echo ""
echo "[cert] 给私钥设置 ACL（避免 codesign 每次弹窗）..."
PASSWORD=$(osascript -e 'tell application "System Events" to display dialog "请输入当前 Mac 登录密码：\n\n用于一次性授权 codesign 访问 macosAsr Local 私钥。\n之后所有 build 都不会再弹钥匙串提示。" default answer "" with hidden answer with title "macosAsr 证书 ACL 配置"' -e 'text returned of result' 2>/dev/null)

if [ -n "$PASSWORD" ]; then
  if security set-key-partition-list \
       -S apple-tool:,apple:,codesign: \
       -s -k "$PASSWORD" \
       "$KEYCHAIN" >/dev/null 2>&1; then
    echo "[cert] ACL 已设置：codesign 将永不再弹窗"
  else
    echo "[cert] [warn] ACL 设置失败（密码错？）。第一次 codesign 时钥匙串会弹「允许」"
    echo "       看到「macosAsr Local 想要访问你的钥匙串」请点「始终允许」"
  fi
else
  echo "[cert] [warn] 未输入密码。第一次 codesign 时钥匙串会弹「允许」对话框"
  echo "       请点「始终允许」（仅一次）"
fi

echo ""
echo "[cert] 完成。验证："
security find-certificate -c "$NAME" -p 2>/dev/null | openssl x509 -noout -subject -ext extendedKeyUsage 2>/dev/null || true
echo ""
echo "下一步：./scripts/build_macapp.sh  （将自动使用该证书签名）"
