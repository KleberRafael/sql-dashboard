#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from openai import OpenAI


def load_json(path: str) -> Any:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--window", required=True)
    parser.add_argument("--review", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--model", default="gpt-4o-mini")
    args = parser.parse_args()

    analysis_window = load_json(args.window)
    review_state = load_json(args.review)

    schema = {
        "type": "object",
        "properties": {
            "summary": {
                "type": "object",
                "properties": {
                    "overall_risk": {"type": "string", "enum": ["low", "medium", "high"]},
                    "new_count": {"type": "integer"},
                    "persistent_count": {"type": "integer"},
                    "resolved_count": {"type": "integer"}
                },
                "required": ["overall_risk", "new_count", "persistent_count", "resolved_count"],
                "additionalProperties": False
            },
            "recommendations": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "fingerprint": {"type": "string"},
                        "status": {"type": "string", "enum": ["new", "persistent", "worsening", "resolved"]},
                        "severity": {"type": "string", "enum": ["low", "medium", "high", "critical"]},
                        "category": {"type": "string"},
                        "title": {"type": "string"},
                        "evidence": {"type": "array", "items": {"type": "string"}},
                        "recommendation": {"type": "string"},
                        "confidence": {"type": "string", "enum": ["low", "medium", "high"]},
                        "consultive_only": {"type": "boolean"},
                        "requires_dba_validation": {"type": "boolean"}
                    },
                    "required": [
                        "fingerprint",
                        "status",
                        "severity",
                        "category",
                        "title",
                        "evidence",
                        "recommendation",
                        "confidence",
                        "consultive_only",
                        "requires_dba_validation"
                    ],
                    "additionalProperties": False
                }
            }
        },
        "required": ["summary", "recommendations"],
        "additionalProperties": False
    }

    instructions = """
Voce e um especialista em SQL Server.
Analise SOMENTE o JSON recebido.
Gere recomendacoes consultivas, nunca operacionais.
Nao invente metricas ausentes.
Evite ruido: para CPU, memoria, waits, IO e locks, so recomende quando houver persistencia ou piora clara.
Para configuracoes, backup, jobs e trace flags, uma mudanca relevante pode virar recomendacao unica.
Sempre explique a evidencia.
Todas as recomendacoes devem vir com consultive_only=true e requires_dba_validation=true.
Use fingerprints estaveis e curtos.
""".strip()

    client = OpenAI()
    response = client.responses.create(
        model=args.model,
        store=False,
        input=[
            {"role": "system", "content": instructions},
            {
                "role": "user",
                "content": json.dumps(
                    {
                        "analysis_window": analysis_window,
                        "manual_review_state": review_state,
                    },
                    ensure_ascii=False,
                ),
            },
        ],
        text={
            "format": {
                "type": "json_schema",
                "name": "sql_server_recommendations",
                "strict": True,
                "schema": schema,
            }
        },
    )

    output = json.loads(response.output_text)
    Path(args.out).write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
