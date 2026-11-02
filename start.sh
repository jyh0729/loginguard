#!/bin/sh
# 컨테이너 시작 스크립트
#  MODEL_SOURCE=demo (기본): 가짜 데모 데이터로 작은 모델을 학습해 바로 띄운다 (1분 이내)
#  MODEL_SOURCE=rba        : 실제 RBA 로그인 데이터셋을 받아 앞 RBA_ROWS 행으로 학습한다 (10~15분, 메모리 8GB 권장)
#  models/model.joblib 이 이미 있으면 (볼륨) 학습을 건너뛴다
set -e
cd /app
export MODEL_PATH="${MODEL_PATH:-models/model.joblib}"
MODEL_SOURCE="${MODEL_SOURCE:-demo}"

if [ "$MODEL_SOURCE" = "rba" ]; then
  export CSV="${CSV:-data/rba.csv}"
  if [ ! -f "$CSV" ]; then
    echo "[start] 실제 RBA 데이터 받기 (앞 ${RBA_ROWS:-2000000}행)"
    python tools/fetch_rba.py --rows "${RBA_ROWS:-2000000}" --out "$CSV"
  fi
  TRAIN_ARGS="--max-train-rows ${MAX_TRAIN_ROWS:-600000}"
else
  export CSV="${CSV:-data/demo.csv}"
  if [ ! -f "$CSV" ]; then
    echo "[start] 데모 데이터 생성: $CSV"
    mkdir -p "$(dirname "$CSV")"
    python tests/make_sample.py "$CSV"
  fi
  TRAIN_ARGS=""
fi

if [ ! -f "$MODEL_PATH" ]; then
  echo "[start] 학습 시작 (MODEL_SOURCE=$MODEL_SOURCE, CSV=$CSV)"
  # shellcheck disable=SC2086
  python model.py --csv "$CSV" --out-dir "$(dirname "$MODEL_PATH")" $TRAIN_ARGS
fi

echo "[start] API 시작 (version=${APP_VERSION:-dev}, model=$MODEL_SOURCE)"
exec uvicorn api:app --host 0.0.0.0 --port 8000
