"""UC1 Strands agent — non-personalized read-only retrieval.

Demonstrates workload-identity-only access to Postgres + Bedrock KB.

This module defines two @tool-decorated functions that the Strands Agent calls:
  - query_database: issues JIT Postgres creds per request, runs SELECT, closes connection.
  - retrieve_from_knowledge_base: obtains ephemeral STS creds, calls Bedrock KB retrieve().

Both tools obtain credentials from Vault on each invocation so no standing
credentials exist in the pod's environment (OBJ-2). The module-level VaultClient
authenticates once at startup (pod lifecycle token cache) and renews via the K8s
SA JWT rotation projected by the Kubernetes token controller (OBJ-1).
"""

import json
import logging
import os
from typing import Any

import psycopg2
import psycopg2.extras
from strands import Agent, tool
from strands.models import BedrockModel

from .vault_client import VaultClient, _build_default_client

logger = logging.getLogger(__name__)

# Module-level VaultClient: authenticated once at startup.
# login() is called in build_uc1_agent() which is invoked during FastAPI startup.
_vault: VaultClient = _build_default_client()


@tool
def query_database(query: str) -> list[dict]:
    """Execute a read-only SQL query against the workshop Postgres database.

    Fetches JIT credentials from Vault for each call — no standing DB passwords.
    The Vault lease (and ephemeral DB user) expires when the connection closes.

    Args:
        query: SQL SELECT statement to execute.

    Returns:
        List of row dicts (column-name → value). Empty list on no results.
    """
    creds = _vault.get_db_credentials(role_name="uc1-readonly")
    db_host = os.getenv("DB_HOST", "")
    db_port = int(os.getenv("DB_PORT", "5432"))
    db_name = os.getenv("DB_NAME", "workshop")

    logger.info(
        "db_query_start",
        extra={
            "vault_username": creds["username"],
            "lease_id": creds["lease_id"],
            "query_preview": query[:120],
        },
    )

    conn = psycopg2.connect(
        host=db_host,
        port=db_port,
        dbname=db_name,
        user=creds["username"],
        password=creds["password"],
    )
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(query)
            rows = [dict(row) for row in cur.fetchall()]
    finally:
        conn.close()

    logger.info(
        "db_query_complete",
        extra={"row_count": len(rows), "lease_id": creds["lease_id"]},
    )
    return rows


@tool
def retrieve_from_knowledge_base(query: str) -> list[str]:
    """Retrieve relevant passages from the Bedrock Knowledge Base.

    Obtains ephemeral STS credentials from Vault on each call. The Bedrock
    bedrock-agent-runtime retrieve() API performs semantic search against the
    AOSS vector index and returns ranked text chunks.

    Args:
        query: Natural-language question or keyword string.

    Returns:
        List of text passages from the Knowledge Base, ordered by relevance.
    """
    kb_region = os.getenv("KB_REGION", "")
    knowledge_base_id = os.getenv("KNOWLEDGE_BASE_ID", "")

    bedrock_session = _vault.get_bedrock_session(kb_region=kb_region)
    client = bedrock_session.client("bedrock-agent-runtime", region_name=kb_region)

    logger.info(
        "kb_retrieve_start",
        extra={"knowledge_base_id": knowledge_base_id, "kb_region": kb_region},
    )

    response = client.retrieve(
        knowledgeBaseId=knowledge_base_id,
        retrievalQuery={"text": query},
        retrievalConfiguration={
            "vectorSearchConfiguration": {
                "numberOfResults": int(os.getenv("KB_MAX_RESULTS", "5")),
            }
        },
    )

    results = [
        item["content"]["text"]
        for item in response.get("retrievalResults", [])
        if item.get("content", {}).get("text")
    ]

    logger.info(
        "kb_retrieve_complete",
        extra={"result_count": len(results), "knowledge_base_id": knowledge_base_id},
    )
    return results


def build_uc1_agent() -> Agent:
    """Construct and return the UC1 Strands Agent.

    Performs one-time Vault Kubernetes auth (OBJ-1) then wires the agent with:
      - BedrockModel using Amazon Nova Pro via CRIS profile (us.amazon.nova-pro-v1:0)
      - A boto3 session for the Bedrock control plane (primary region, from REGION env var)
      - Two tools: query_database + retrieve_from_knowledge_base

    The bedrock_session passed to BedrockModel is for model invocations only;
    each tool call independently fetches its own ephemeral credentials from Vault.

    Returns:
        Configured strands.Agent ready to handle queries.
    """
    global _vault

    # Authenticate once at startup; token is cached for the pod's lifetime.
    _vault.login()

    region = os.getenv("REGION", "")
    kb_region = os.getenv("KB_REGION", "")
    model_id = os.getenv("BEDROCK_MODEL_ID", "us.amazon.nova-pro-v1:0")

    # Obtain an STS session for the model invocation plane (primary region).
    bedrock_session = _vault.get_bedrock_session(kb_region=region)

    bedrock_model = BedrockModel(
        model_id=model_id,
        boto_session=bedrock_session,
    )

    system_prompt = (
        "You are a workshop demonstration agent for the Agentic Runtime Security on AWS workshop. "
        "You operate in Use Case 1 (non-personalized read-only mode): you have NO user identity context — "
        "all database and knowledge base access uses workload-identity-only (Kubernetes Service Account) credentials. "
        "Your capabilities: "
        "(1) query_database — run read-only SQL against the workshop Postgres database using Just-In-Time Vault credentials; "
        "(2) retrieve_from_knowledge_base — semantic search against the Bedrock Knowledge Base using ephemeral STS credentials. "
        "Always cite credential metadata (lease_id, ttl) in your reasoning to demonstrate OBJ-5 audit correlation. "
        "Never request, store, or disclose user-identifying information — this use case is intentionally non-personalized."
    )

    agent = Agent(
        model=bedrock_model,
        tools=[query_database, retrieve_from_knowledge_base],
        system_prompt=system_prompt,
    )

    logger.info(
        "uc1_agent_built",
        extra={
            "model_id": model_id,
            "region": region,
            "kb_region": kb_region,
            "tools": ["query_database", "retrieve_from_knowledge_base"],
        },
    )
    return agent
