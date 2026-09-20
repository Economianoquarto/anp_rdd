# PMPF do CONFAZ — extração e auditoria

Reconstrói `../PMPF_2026_CONFAZ.xlsx` a partir dos **PDFs dos Atos COTEPE/PMPF
publicados no DOU**, e audita a planilha antiga contra essa fonte.

## Por que isso existe

A versão anterior da planilha tinha 11 das 15 vigências do período
(faltavam `2026-01-01`, `2026-02-01`, `2026-03-01` e `2026-08-01`, marcadas
como "NAO recuperado"). As duas do meio são justamente as quinzenas em que a
PMPF do etanol de **PE mudou**, então o painel semanal do `main.R` datava duas
das mudanças de PE ~15 dias depois do que aconteceu de fato.

## Como rodar

```bash
powershell -File 00_baixa_pdfs.ps1        # baixa os 22 PDFs para ./pdf_dou
python 01_consolida_dou.py                # PDFs + transcrições -> pmpf_dou_2026.csv
python 02_audita_e_gera_planilha.py       # audita e regrava ../PMPF_2026_CONFAZ.xlsx
```

Dependências: `pdfplumber` e `openpyxl` (`pip install pdfplumber openpyxl`).
A etapa 2 salva um backup `PMPF_2026_CONFAZ_backup_<data>.xlsx` antes de
sobrescrever. As etapas 1 e 2 rodam offline (os PDFs já estão em `pdf_dou/`).

## Arquivos

| arquivo | o que é |
|---|---|
| `pdf_dou/` | PDFs dos atos, como publicados no DOU (fonte primária) |
| `transcricoes_dou.csv` | transcrição **manual** dos atos cujo PDF é só imagem |
| `correcoes_dou.csv` | atos de alteração e a retificação, com valor antes/depois |
| `pmpf_dou_2026.csv` | saída da etapa 1: tabela verbatim, 15 vigências × 27 UFs |
| `atos_metadados.csv` | datas de ato/DOU/vigência lidas dos PDFs |

## Duas armadilhas da fonte

**1. Não use a página HTML do `confaz.fazenda.gov.br` para copiar valores.**
Na conferência de 17/09/2026 ela devolveu números divergentes do DOU:

- Ato 7 (vig. 01/04): HTML deu `AC 5,2254 / AM 5,4413 / AP 5,7900`;
  o DOU traz `AC *5,3984 / AM *5,5409 / AP 5,8900`.
- Ato 5 (vig. 01/03): HTML mostrou `PE *5,1800` já dentro do corpo da tabela,
  embutindo a retificação; o DOU publicou `PE 4,9200`.
- Ato 2 (vig. 01/02): HTML deu `TO *5,1100`, que é o valor **depois** do
  Ato 3; o DOU publicou `TO 4,8200`.

O padrão é a página consolidar correções posteriores sem avisar. Use os PDFs.

**2. Sete PDFs são imagem, sem camada de texto** (Ato 31/2025 e Atos 1, 2, 3,
4, 5 e 20/2026) — nem `pdfplumber` nem `pypdfium2` extraem nada. Esses foram
transcritos à mão em `transcricoes_dou.csv`, célula por célula, com os
asteriscos originais. Para conferir, abra o PDF em `pdf_dou/` e compare com a
coluna `fonte_dou` (que traz edição, seção e página do DOU).

## Resultado da auditoria (17/09/2026)

Nas 11 vigências que as duas versões têm em comum, **638 células conferidas,
zero divergência de valor**: os números que já estavam na planilha estão
corretos. As 17 divergências encontradas são todas nas colunas de marcação
`Alterado (*)` / `Redução (**)`, e todas em células que um ato posterior
corrigiu (SE em 01/04; RJ e SE em 16/04; AM e GO em 01/06) — a versão antiga
aplicava o valor corrigido mas deixava a marcação em branco. É por isso que
essas colunas "não batiam" com a série de valores. Agora batem.
