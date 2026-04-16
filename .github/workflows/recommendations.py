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
    parser.add_argument("--model", default="gpt-5.4")
    args = parser.parse_args()

    analysis_window = load_json(args.window)
    review_state = load_json(args.review)

    schema = {
        "type": "object",
        "properties": {
            "summary": {
                "type": "object",
                "properties": {
                    "overall_risk": {"type": "string", "enum": ["low", "medium", "high", "critical"]},
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
                        "why_it_matters": {"type": "string"},
                        "recommendation": {"type": "string"},
                        "suggested_action": {"type": "string"},
                        "sql_example": {"type": "string"},
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
                        "why_it_matters",
                        "recommendation",
                        "suggested_action",
                        "sql_example",
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
Você é um especialista sênior em SQL Server, performance, capacity planning, operação de backups/jobs e TOTVS Protheus.

Tarefa:
1. Analise SOMENTE o JSON recebido.
2. Gere recomendações consultivas para o time DBA.
3. Nunca invente métricas ausentes.
4. Nunca proponha execução automática. Toda ação deve ser validada pelo DBA.
5. Para CPU, memória, waits, IO, locks, slow queries, missing indexes e fragmentação, só recomende quando houver persistência, piora clara ou severidade objetiva.
6. Para backups, jobs, configurações, trace flags e itens operacionais, uma mudança relevante pode virar recomendação única.
7. Cubra todos os itens relevantes levantados pelo dashboard: ambiente, performance, operações e Protheus, quando houver evidência.
8. Prefira recomendações específicas e priorizadas. Evite frases genéricas.
9. Se o dado for insuficiente, use confidence="low" e recomende investigação em vez de alteração.
10. Todas as recomendações devem ter consultive_only=true e requires_dba_validation=true.
11. Use fingerprints estáveis, curtos e legíveis, por exemplo: memory|ple|low, backups|full|stale, jobs|failed|recent.
12. Se não houver recomendação relevante, devolva recommendations=[] e summary coerente.

Campos esperados:
- evidence: 2 a 5 evidências concretas
- why_it_matters: por que isso importa para o ambiente
- recommendation: recomendação principal em linguagem clara
- suggested_action: próximo passo objetivo para o DBA
- sql_example: exemplo opcional; se não fizer sentido, devolva string vazia
""".strip()

    client = OpenAI(timeout=120.0)
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
