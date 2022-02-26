#!/bin/bash

#SBATCH -N 1 
#SBATCH -n 1
#SBATCH --gres=gpu:2
#SBATCH -t 0:5:0
#SBATCH --account=-Heterogeneity-Aware
#SBATCH -p gtx


echo "Run model: $1"

if [ $1 == "resnet18" ]
then
    #cd /work/03924/xuehaiq/maverick2/jcy_workspace/FlexFlow && rm -rf build && mkdir build && cd build && ../config/config.linux && make
    cd /work/03924/xuehaiq/maverick2/jcy_workspace/FlexFlow && python3 examples/python/onnx/resnet18_pt.py && python/flexflow_python examples/python/onnx/resnet18.py -ll:py 1 -ll:gpu 2 -ll:fsize 8192 -ll:zsize 16384 --epochs 1 -ll:streams 1 -b 128
elif [ $1 == "resnet18_default_strategy" ]
then
    cd /work/03924/xuehaiq/maverick2/jcy_workspace/FlexFlow && ./python/flexflow_python ./examples/python/onnx/resnet18.py -ll:py 1 -ll:gpu 2 -ll:fsize 8192 -ll:zsize 16384 --epochs 1 -ll:streams 1 -b 128 --simulator-workspace-size 524288000 --search-budget 10 --export-strategy strategy_default.txt
elif [ $1 == "resnet18_all_strategy" ]
then
    cd /work/03924/xuehaiq/maverick2/jcy_workspace/FlexFlow && ./python/flexflow_python ./examples/python/onnx/resnet18.py -ll:py 1 -ll:gpu 2 -ll:fsize 8192 -ll:zsize 16384 --epochs 1 -ll:streams 1 -b 128 --enable-parameter-parallel --enable-attribute-parallel --simulator-workspace-size 524288000 --search-budget 10 --export-strategy strategy_all.txt
elif [ $1 == "mnist" ]
then
    cd /work/03924/xuehaiq/maverick2/jcy_workspace/FlexFlow && ./python/flexflow_python $FF_HOME/examples/python/native/mnist_mlp.py -ll:py 1 -ll:gpu 2 -ll:fsize 8192 -ll:zsize 16384 --simulator-workspace-size 524288000 --epochs 5 --search-budget 10 --export-strategy strategy_mnist.txt
fi

