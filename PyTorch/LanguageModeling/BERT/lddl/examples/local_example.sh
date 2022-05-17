#!/bin/bash

#
# This bash script demonstrates how to use LDDL end-to-end (i.e., from
# downloading the raw dataset to loading the input batches during training) on
# a local machine for (mock) BERT Phase 2 pretraining with static masking and
# sequence binning enabled.
#

set -eux

# Build a NGC PyTorch container image that has lddl installed.
bash docker/build.sh

# Create a directory to store data.
mkdir -p data/

# Download the Wikipedia dump.
readonly wikipedia_path=data/wikipedia
bash docker/interactive.sh "" "download_wikipedia --outdir ${wikipedia_path}"

# Download the vocab file from NVIDIA Deep Learning Examples (but you can
# certainly get it from other sources as well).
readonly vocab_source_url=https://raw.githubusercontent.com/NVIDIA/DeepLearningExamples/master/PyTorch/LanguageModeling/BERT/vocab/vocab
mkdir -p data/vocab/
readonly vocab_path=data/vocab/bert-en-uncased.txt
wget ${vocab_source_url} -O ${vocab_path}

# Run the LDDL preprocessor for BERT Phase 2 pretraining with static masking and
# sequence binning enabled (where the bin size is 64).
readonly num_shards=4096
readonly bin_size=64
readonly jemalloc_path=/opt/conda/lib/libjemalloc.so
readonly pretrain_input_path=data/bert/pretrain/phase2/bin_size_${bin_size}/
bash docker/interactive.sh "" " \
  mpirun \
    --oversubscribe \
    --allow-run-as-root \
    -np $(nproc) \
    -x LD_PRELOAD=${jemalloc_path} \
      preprocess_bert_pretrain \
        --schedule mpi \
        --vocab-file ${vocab_path} \
        --wikipedia ${wikipedia_path}/source/ \
        --sink ${pretrain_input_path} \
        --target-seq-length 512 \
        --num-blocks ${num_shards} \
        --bin-size ${bin_size} \
        --masking "

# Run the LDDL load balancer to balance the parquet shards generated by the LDDL
# preprocessor.
bash docker/interactive.sh "" " \
  mpirun \
    --oversubscribe \
    --allow-run-as-root \
    -np $(nproc) \
      balance_dask_output \
        --indir ${pretrain_input_path} \
        --num-shards ${num_shards} "

# Run a mock PyTorch training script that loads the input from the balanced
# parquet shards using the LDDL data loader.
# Once these training processes is up and running (as you can see from the
# stdout printing), it simply emulates training and you can kill it at any time.
readonly sequence_length_distribution_path=data/experiments/phase2/bin_size_${bin_size}/
bash docker/interactive.sh "" " \
  python -m torch.distributed.launch --nproc_per_node=2 \
    benchmarks/torch_train.py \
      --path ${pretrain_input_path} \
      --vocab-file ${vocab_path} "