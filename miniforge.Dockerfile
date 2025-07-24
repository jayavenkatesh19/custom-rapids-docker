# syntax=docker/dockerfile:1
# Copyright (c) 2024-2025, NVIDIA CORPORATION.

ARG CUDA_VER=12.8.0
ARG PYTHON_VER=3.10
ARG LINUX_DISTRO=ubuntu
ARG LINUX_DISTRO_VER=22.04
ARG RAPIDS_VER=25.08

# Base image with minimal RAPIDS components using miniforge-cuda
FROM rapidsai/miniforge-cuda:${RAPIDS_VER}-cuda${CUDA_VER}-base-${LINUX_DISTRO}${LINUX_DISTRO_VER}-py${PYTHON_VER} AS base

ARG CUDA_VER
ARG PYTHON_VER
ARG RAPIDS_VER

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Install minimal system dependencies
RUN apt-get update && rm -rf /var/lib/apt/lists/*

# Copy conda configuration
COPY condarc /opt/conda/.condarc

# Create rapids user with conda group (conda group already exists in miniforge-cuda)
RUN useradd -rm -d /home/rapids -s /bin/bash -g conda -u 1001 rapids

USER rapids
WORKDIR /home/rapids

# Copy conda config to user home as well
RUN cp /opt/conda/.condarc ~/.condarc

# Create RAPIDS environment with only cudf and cuml
RUN conda create -y -n rapids-env \
    cudf=${RAPIDS_VER} \
    cuml=${RAPIDS_VER} \
    python=${PYTHON_VER} \
    'cuda-version>=12.0,<=12.8' \
    ipython
    
RUN conda clean --all --yes && \
    echo ". /opt/conda/etc/profile.d/conda.sh; conda activate rapids-env" >> ~/.bashrc

# Copy and setup entrypoint script
COPY entrypoint.sh /home/rapids/entrypoint.sh

# Make entrypoint executable and fix ownership
USER root
RUN chown rapids:conda /home/rapids/entrypoint.sh && \
    chmod +x /home/rapids/entrypoint.sh

USER rapids

# Set default environment
ENV CONDA_DEFAULT_ENV=rapids-env

# Use the same entrypoint for both base and notebooks
ENTRYPOINT ["/home/rapids/entrypoint.sh"]
CMD ["ipython"]

# Notebooks image - extends base with minimal Jupyter
FROM base AS notebooks

USER rapids
WORKDIR /home/rapids

# Install Jupyter packages directly in the existing environment
RUN conda install -y -n rapids-env \
    "jupyterlab=4" \
    dask-labextension \
    jupyterlab-nvdashboard && \
    conda clean --all --yes

# Disable the JupyterLab announcements
RUN /opt/conda/envs/rapids-env/bin/jupyter labextension disable "@jupyterlab/apputils-extension:announcements"

# Set up Dask configuration for CUDA clusters
ENV DASK_LABEXTENSION__FACTORY__MODULE="dask_cuda"
ENV DASK_LABEXTENSION__FACTORY__CLASS="LocalCUDACluster"

# Create notebooks directory
RUN mkdir -p /home/rapids/notebooks

EXPOSE 8888

# Same entrypoint as base, but different CMD for Jupyter
ENTRYPOINT ["/home/rapids/entrypoint.sh"]
CMD ["sh", "-c", "jupyter lab --notebook-dir=/home/rapids/notebooks --ip=0.0.0.0 --no-browser --NotebookApp.token='' --NotebookApp.allow_origin='*' --NotebookApp.base_url=\"${NB_PREFIX:-/}\""]

# Minimal metadata
LABEL com.nvidia.rapids.version="${RAPIDS_VER}"
LABEL com.nvidia.cuda.version="${CUDA_VER}"
LABEL com.nvidia.rapids.components="cudf,cuml"
