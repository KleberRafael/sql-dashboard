# ============================================================
#  pushassessment.ps1  -- versao multi-instancia (Modelo A)
#  Roda LOCALMENTE em cada instancia de PRODUCAO, via SQL Agent Job.
#  Coleta -> serializa data-<slug>.json -> atualiza manifest -> git push.
#
#  Cada execucao e autonoma: nao precisa enxergar outras instancias.
#  So precisa de: (1) acesso a esta instancia  (2) saida HTTPS p/ GitHub.
# ============================================================

# ============================================================
#  CONFIG  -- AJUSTE ESTAS 4 LINHAS POR INSTANCIA
# ============================================================
$Cliente   = "TESTE"                 # nome do cliente
$SqlInst   = "."                    # "." = instancia default | ".\NOMEINST" = nomeada
$RepoPath  = "C:\sql-dashboard"     # pasta do repo git local (clone do repo do cliente)
$GitExe    = "C:\Program Files\Git\cmd\git.exe"   # caminho ABSOLUTO (conta de servico nao tem PATH)
# ============================================================

$ErrorActionPreference = "Stop"

# git escreve mensagens de status normais no stderr. Esta funcao executa o git
# sem que o PowerShell trate essas mensagens como erro fatal: captura tudo,
# imprime, e devolve apenas o exit code real para a logica de retry decidir.
function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments=$true)] $Args)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # nao transformar stderr em excecao
    # captura toda a saida (stdout+stderr) num array, guarda o exit code do git
    # IMEDIATAMENTE, e so depois imprime — assim o pipe nao sobrescreve o codigo
    $out = & $GitExe @Args 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    foreach ($line in $out) { Write-Host $line.ToString() }
    return [int]$code
}

# 1) roda o assessment e le a tabela ja carimbada
Invoke-Sqlcmd -ServerInstance $SqlInst -Database dba_admin `
    -Query "EXEC run_assessment @cliente=N'$Cliente';" | Out-Null

$rows = Invoke-Sqlcmd -ServerInstance $SqlInst -Database dba_admin -Query @"
SELECT id, cliente, servidor, instancia,
       CONVERT(varchar(19), coletado_em, 126) AS coletado_em,
       secao, metrica, valor, status, detalhe
FROM assessment_report ORDER BY id;
"@

# 2) identidade vinda dos proprios dados
$srv  = ($rows | Select-Object -First 1).servidor
$inst = ($rows | Select-Object -First 1).instancia

function Clean([string]$s){ ($s -replace '[^A-Za-z0-9_-]','_') }
$slug = "$(Clean $Cliente)-$(Clean $srv)-$(Clean $inst)"
$jsonFile = Join-Path $RepoPath "data-$slug.json"

# 3) serializa
$rows | Select-Object id,cliente,servidor,instancia,coletado_em,secao,metrica,valor,status,detalhe `
      | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 $jsonFile

# 4) atualiza o manifesto
$manifestPath = Join-Path $RepoPath "manifest.json"
$entry = [pscustomobject]@{
    slug=$slug; cliente=$Cliente; servidor=$srv; instancia=$inst;
    file="data-$slug.json"; atualizado=(Get-Date -Format s)
}
$manifest = @()
if (Test-Path $manifestPath) { $manifest = @(Get-Content $manifestPath -Raw | ConvertFrom-Json) }
$manifest = @($manifest | Where-Object { $_.slug -ne $slug }) + $entry
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 $manifestPath

# 5) git push com retry/rebase (resolve colisao se 2 instancias do mesmo
#    cliente derem push quase juntas)
# Usa Invoke-Git para que mensagens de status do git (que vao p/ stderr)
# nao virem falso-erro no PowerShell nem no SQL Agent.
Set-Location $RepoPath
Invoke-Git add -- "data-$slug.json" "manifest.json" | Out-Null
Invoke-Git commit -m "assessment $slug $(Get-Date -Format s)" --allow-empty | Out-Null

$maxTentativas = 5
for ($i=1; $i -le $maxTentativas; $i++) {
    $code = Invoke-Git push
    if ($code -eq 0) { Write-Output "push OK (tentativa $i)"; break }
    Write-Output "push rejeitado, sincronizando (tentativa $i/$maxTentativas)..."
    Invoke-Git pull --rebase --autostash | Out-Null
    if ($i -eq $maxTentativas) { throw "git push falhou apos $maxTentativas tentativas" }
    Start-Sleep -Seconds ([math]::Min(2*$i, 10))
}
