#!/bin/sh
# 컨테이너 시작 스크립트
#  - models/model.joblib 이 없으면: 데모용 가짜 RBA 데이터로 작은 모델을 학습해서 띄운다
#    (실제 RBA 모델을 쓰려면 Colab에서 학습한 model.joblib 을 models/ 에 넣고 빌드하거나 볼륨으로 붙인다)
#  - CSV 가 없으면 관제 화면 재생용 데모 데이터를 만든다
set -e
cd /app
export MODEL_PATH="${MODEL_PATH:-models/model.joblib}"
export CSV="${CSV:-data/demo.csv}"

if [ ! -f "$CSV" ]; then
  echo "[start] 데모 데이터 생성: $CSV"
  mkdir -p "$(dirname "$CSV")"
  python tests/make_sample.py "$CSV"
fi
if [ ! -f "$MODEL_PATH" ]; then
  echo "[start] 모델 파일이 없어 데모 데이터로 학습: $MODEL_PATH"
  python model.py --csv "$CSV" --out-dir "$(dirname "$MODEL_PATH")"
fi

echo "[start] API 시작 (version=${APP_VERSION:-dev})"
exec uvicorn api:app --host 0.0.0.0 --port 8000
