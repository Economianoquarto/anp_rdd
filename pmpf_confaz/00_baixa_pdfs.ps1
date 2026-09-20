# Etapa 0: baixa os PDFs dos Atos COTEPE/PMPF publicados no DOU.
#
# Fonte: espelho da Revenda Conectada (Sindicombustiveis-PE), que republica o
# PDF do DOU sem alteracao. Usamos esse espelho porque:
#   - o confaz.fazenda.gov.br bloqueia acesso automatizado; e
#   - a versao HTML do CONFAZ mostrou valores errados na auditoria
#     (ver comentario no topo de 01_consolida_dou.py).
#
# Por que PowerShell e nao Python/curl: este host recusa o handshake TLS do
# urllib e do curl do Git Bash (sem CA bundle). O Invoke-WebRequest usa o
# armazenamento de certificados do Windows e funciona.
#
# Uso (a partir desta pasta):  powershell -File 00_baixa_pdfs.ps1

$dir = Join-Path $PSScriptRoot "pdf_dou"
New-Item -ItemType Directory -Force $dir | Out-Null

# 2026: atos 1..21 (bases quinzenais + alteracoes).
# 2025: ato 31 e' o que vigora a partir de 01/01/2026 - por isso entra aqui.
$alvos = @()
foreach ($i in 1..21) { $alvos += [pscustomobject]@{ Ano = 2026; N = $i } }
$alvos += [pscustomobject]@{ Ano = 2025; N = 31 }

foreach ($a in $alvos) {
  $n   = "{0:d2}" -f $a.N
  $out = Join-Path $dir ("ato_{0}_{1}.pdf" -f $a.Ano, $n)
  if (Test-Path $out) { Write-Output "ja existe: $(Split-Path $out -Leaf)"; continue }
  $url = "https://www.revendaconectada.com.br/arqConteudo/arqAtoCotepe/Ato_Cotepe_$($a.Ano)_$n.pdf"
  try {
    Invoke-WebRequest -Uri $url -OutFile $out -TimeoutSec 60 -UseBasicParsing
    Write-Output ("ok {0}/{1}  {2} bytes" -f $a.Ano, $n, (Get-Item $out).Length)
  } catch {
    Write-Output ("FALHA {0}/{1}  {2}" -f $a.Ano, $n, $_.Exception.Message)
  }
}
