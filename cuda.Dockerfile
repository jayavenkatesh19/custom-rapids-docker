# syntax=docker/dockerfile:1
# Copyright (c) 2024-2025, NVIDIA CORPORATION.

ARG CUDA_VER=12.8
ARG PYTHON_VER=3.10
ARG LINUX_DISTRO=ubuntu
ARG LINUX_DISTRO_VER=22.04
ARG RAPIDS_VER=25.08

# Base image using CUDA runtime instead of miniforge-cuda
FROM nvidia/cuda:${CUDA_VER}.0-runtime-${LINUX_DISTRO}${LINUX_DISTRO_VER} AS base

ARG CUDA_VER
ARG PYTHON_VER
ARG RAPIDS_VER

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Install minimal system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Download and install Miniforge manually
RUN curl -L "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-$(uname)-$(uname -m).sh" -o miniforge.sh && \
    bash miniforge.sh -b -p /opt/conda && \
    rm miniforge.sh

# Set up conda environment path
ENV PATH=/opt/conda/bin:$PATH

# Ensure conda environment is always activated
RUN <<EOF
ln -s /opt/conda/etc/profile.d/conda.sh /etc/profile.d/conda.sh
echo ". /opt/conda/etc/profile.d/conda.sh; conda activate base" >> /etc/skel/.bashrc
echo ". /opt/conda/etc/profile.d/conda.sh; conda activate base" >> ~/.bashrc
EOF

# Copy conda configuration
COPY condarc /opt/conda/.condarc

# Create conda group and set permissions for conda installation
RUN groupadd conda && \
    chown -R root:conda /opt/conda && \
    chmod -R g+w /opt/conda

# Create rapids user with conda group
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
    ipython && \
    conda clean --all --yes && \
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