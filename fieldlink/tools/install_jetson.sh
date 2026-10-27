#!/usr/bin/env bash
# Jetson Orin Nano 安裝腳本
# 自動判斷 JetPack 6（L4T R36，Ubuntu 22.04）或 JetPack 7（L4T R38 以上，Ubuntu 24.04，CUDA 13）
# 在專案根目錄執行：./tools/install_jetson.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

L4T="$(head -n1 /etc/nv_tegra_release | sed -E 's/^# R([0-9]+).*/\1/')"
PYV="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
echo "==> L4T R${L4T}，Python ${PYV}"

echo "==> 系統套件（GNU Radio、UHD、gr-dvbs2rx 編譯相依）"
sudo apt update
sudo apt install -y nvidia-jetpack \
  gnuradio gnuradio-dev uhd-host libuhd-dev \
  cmake git pkg-config libsndfile1-dev libspdlog-dev pybind11-dev python3-packaging doxygen graphviz \
  python3-venv python3-pip libnotify-bin network-manager openssl curl wget unzip
sudo uhd_images_downloader -t b2xx

echo "==> gr-dvbs2rx（DVB-S2 收發，LDPC 有 NEON 加速）"
if ! command -v dvbs2-rx >/dev/null; then
  rm -rf /tmp/gr-dvbs2rx
  git clone --recursive https://github.com/igorauad/gr-dvbs2rx.git /tmp/gr-dvbs2rx
  cmake -S /tmp/gr-dvbs2rx -B /tmp/gr-dvbs2rx/build -DCMAKE_BUILD_TYPE=Release
  cmake --build /tmp/gr-dvbs2rx/build -j"$(nproc)"
  sudo cmake --install /tmp/gr-dvbs2rx/build
  sudo ldconfig
fi
/usr/bin/python3 -c "import gnuradio.dvbs2rx; print('gr-dvbs2rx OK')"

echo "==> Python 虛擬環境 .venv"
# --system-site-packages：看得到 apt 裝的 TensorRT Python binding
# Ubuntu 24.04 不允許 pip 直接裝到系統，所以專案套件都裝在 .venv
python3 -m venv --system-site-packages .venv
. .venv/bin/activate
python -m pip install -U pip

if [ "${L4T}" -ge 38 ]; then
  echo "==> PyTorch（JetPack 7.x，CUDA 13）"
  pip install torch torchvision --index-url https://download.pytorch.org/whl/cu130
else
  echo "==> PyTorch（JetPack 6.x，Python 3.10）"
  pip install \
    https://github.com/ultralytics/assets/releases/download/v0.0.0/torch-2.10.0-cp310-cp310-linux_aarch64.whl \
    https://github.com/ultralytics/assets/releases/download/v0.0.0/torchvision-0.25.0-cp310-cp310-linux_aarch64.whl
  wget -q -O /tmp/cudss.deb \
    https://developer.download.nvidia.com/compute/cudss/0.7.1/local_installers/cudss-local-tegra-repo-ubuntu2204-0.7.1_0.7.1-1_arm64.deb
  sudo dpkg -i /tmp/cudss.deb
  sudo cp /var/cudss-local-tegra-repo-ubuntu2204-0.7.1/cudss-*-keyring.gpg /usr/share/keyrings/
  sudo apt-get update && sudo apt-get -y install cudss
fi

# 先裝好 Jetson 用的 torch，再裝 ultralytics，避免 pip 換成不支援 GPU 的 torch
pip install ultralytics aiohttp pyyaml pillow

echo "==> 檢查 GPU 與 TensorRT"
python - << 'PY'
import torch
print("torch", torch.__version__, "CUDA 可用:", torch.cuda.is_available())
try:
    import tensorrt
    print("TensorRT", tensorrt.__version__)
except ImportError:
    print("找不到 TensorRT Python binding：請確認 nvidia-jetpack 已安裝；不要用 pip 安裝 tensorrt")
PY

echo "==> Ollama 與 VLM"
if ! command -v ollama >/dev/null; then curl -fsSL https://ollama.com/install.sh | sh; fi
ollama pull qwen3-vl:2b

echo
echo "完成。接下來："
echo "  1. 切換到最高效能模式：grep POWER_MODEL /etc/nvpmodel.conf 找到 MAXN_SUPER 的 ID，再 sudo nvpmodel -m <ID>"
echo "  2. sudo jetson/setup_hotspot.sh 熱點名稱 密碼"
echo "  3. jetson/gen_cert.sh"
echo "  4. .venv/bin/python jetson/app.py（第一次會下載 yolo26s 並匯出 TensorRT，約數分鐘）"
