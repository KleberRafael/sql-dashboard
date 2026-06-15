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
# Nota: git escreve status normal no stderr. Capturamos com 2>&1 e deixamos
# o exit code decidir o sucesso, evitando falso-erro no PowerShell e no Agent.
Set-Location $RepoPath
$saida = & $GitExe add -- "data-$slug.json" "manifest.json" 2>&1
$saida = & $GitExe commit -m "assessment $slug $(Get-Date -Format s)" --allow-empty 2>&1
Write-Output $saida

$maxTentativas = 5
for ($i=1; $i -le $maxTentativas; $i++) {
    $saida = & $GitExe push 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Output "push OK (tentativa $i)"; break }
    Write-Output "push rejeitado, sincronizando (tentativa $i/$maxTentativas)..."
    Write-Output $saida
    $saida = & $GitExe pull --rebase --autostash 2>&1
    Write-Output $saida
    if ($i -eq $maxTentativas) { throw "git push falhou apos $maxTentativas tentativas" }
    Start-Sleep -Seconds ([math]::Min(2*$i, 10))
}