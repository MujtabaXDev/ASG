#!/bin/bash
# User data for the Launch Template (works on Ubuntu and Amazon Linux 2023).
# Put index.html in the root of your GitHub repo and set REPO_URL below.
REPO_URL="https://github.com/MujtabaXDev/ASG.git"

# Detect OS: Ubuntu uses apt and /var/www/html, Amazon Linux uses dnf
if command -v apt-get >/dev/null; then
  WEB=/var/www/html
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y nginx git curl
else
  WEB=/usr/share/nginx/html
  dnf install -y nginx git
fi

git clone "$REPO_URL" /opt/app
cp /opt/app/index.html $WEB/index.html
echo ok > $WEB/health   # use /health as the target group health check path

# Collector: writes metrics.json every 3 seconds, the dashboard reads it
cat > /usr/local/bin/collect-metrics.sh <<'COLLECTOR'
#!/bin/bash
OUT=/usr/share/nginx/html
IMDS=http://169.254.169.254/latest
tok()  { curl -s -X PUT "$IMDS/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60"; }
meta() { curl -sf -H "X-aws-ec2-metadata-token: $T" "$IMDS/meta-data/$1"; }

T=$(tok)
ID=$(meta instance-id); TYPE=$(meta instance-type); AZ=$(meta placement/availability-zone)
PRIV=$(meta local-ipv4); PUB=$(meta public-ipv4); HOST=$(meta hostname); AMI=$(meta ami-id)
ASG=$(meta tags/instance/aws:autoscaling:groupName)   # needs "Allow tags in instance metadata" on the template
PUB=${PUB:-none}; ASG=${ASG:-n/a}; VCPU=$(nproc)

read -r _ u n s i io irq sq st _ < /proc/stat
PT=$((u+n+s+i+io+irq+sq+st)); PI=$((i+io))

while true; do
  sleep 3
  T=$(tok); STATE=$(meta autoscaling/target-lifecycle-state); STATE=${STATE:-InService}
  read -r _ u n s i io irq sq st _ < /proc/stat
  CT=$((u+n+s+i+io+irq+sq+st)); CI=$((i+io))
  CPU=$(awk -v dt=$((CT-PT)) -v di=$((CI-PI)) 'BEGIN{printf "%.1f", (dt>0 ? 100*(dt-di)/dt : 0)}')
  PT=$CT; PI=$CI
  read -r L1 L5 L15 _ < /proc/loadavg
  read -r MT MU < <(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{print int(t/1024), int((t-a)/1024)}' /proc/meminfo)
  DISK=$(df -P / | awk 'NR==2{gsub("%","",$5);print $5}')
  UP=$(awk '{print int($1)}' /proc/uptime)
  cat > $OUT/metrics.json.tmp <<EOF
{"id":"$ID","type":"$TYPE","az":"$AZ","privateIp":"$PRIV","publicIp":"$PUB","hostname":"$HOST",
"ami":"$AMI","asg":"$ASG","state":"$STATE","vcpu":$VCPU,"cpu":$CPU,"memUsedMb":$MU,"memTotalMb":$MT,
"disk":$DISK,"load1":$L1,"load5":$L5,"load15":$L15,"uptime":$UP}
EOF
  mv $OUT/metrics.json.tmp $OUT/metrics.json
done
COLLECTOR
sed -i "s|^OUT=.*|OUT=$WEB|" /usr/local/bin/collect-metrics.sh   # use the web root detected above
chmod +x /usr/local/bin/collect-metrics.sh

cat > /etc/systemd/system/collect-metrics.service <<'UNIT'
[Unit]
Description=Instance metrics collector
After=network-online.target
[Service]
ExecStart=/usr/local/bin/collect-metrics.sh
Restart=always
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now nginx collect-metrics

# To trigger a scale-out for testing, SSH into an instance and run:
#   for i in $(seq $(nproc)); do yes > /dev/null & done      (stop with: pkill yes)