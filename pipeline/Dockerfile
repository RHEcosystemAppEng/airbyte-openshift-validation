# Ray runtime image for the EDGAR RAG ingestion pipeline.
#
# Contains the pipeline package plus Docling / sentence-transformers /
# pymilvus / boto3. Use an immutable tag or digest in the RayCluster and
# RayJob manifests.
#
# Build (from repo root):
#   docker build -f pipeline/Dockerfile -t quay.io/<org>/edgar-rag-ray:0.1.0 .
#   docker push quay.io/<org>/edgar-rag-ray:0.1.0
#
# Or pin by digest after push:
#   docker build -f pipeline/Dockerfile -t quay.io/<org>/edgar-rag-ray:0.1.0 .
#   dig=$(docker inspect --format='{{index .RepoDigests 0}}' quay.io/<org>/edgar-rag-ray:0.1.0)
#   # set manifests to that digest

FROM rayproject/ray:2.54.0-py311

USER root
RUN mkdir -p /opt/edgar-rag && chown -R ray:ray /opt/edgar-rag
USER ray

WORKDIR /opt/edgar-rag

COPY --chown=ray:ray pipeline/requirements.txt /opt/edgar-rag/pipeline/requirements.txt
RUN pip install --no-cache-dir -r /opt/edgar-rag/pipeline/requirements.txt

COPY --chown=ray:ray pipeline/ /opt/edgar-rag/pipeline/

ENV PYTHONPATH=/opt/edgar-rag
WORKDIR /opt/edgar-rag

# Entrypoint for RayJob: python -m pipeline.edgar_rag_pipeline
CMD ["python", "-m", "pipeline.edgar_rag_pipeline"]
