# Contexto do projeto

Log de decisões importantes do pipeline em [main.R](main.R). Objetivo: evitar
retrabalho e re-descoberta de coisas ja resolvidas em conversas anteriores.

## O que o script faz

Junta 3 fontes de dados sobre postos de combustivel em Juazeiro(BA) e
Petrolina(PE):
- `postos_2026_01.csv` — serie de precos coletados pela ANP (formato longo:
  1 linha por posto/produto/coleta).
- `juazeiro.xlsx` / `petrolina.xlsx` — cadastro de postos (`petjua`): tancagem,
  qtde de bico, endereco etc.
- `PMPF_2026_CONFAZ.xlsx` — preco de referencia (PMPF) do etanol (AEHC) por UF,
  usado para achar mudancas de PMPF em BA e PE.

Resultado final: `petjua_postos`, painel cnpj x semana com precos praticados +
PMPF de referencia do etanol quando aplicavel.

## Decisões e por quê

- **Semana de calendario (dom-sab), nao bloco fixo de 7 dias a partir de
  01/01.** Bloco fixo desalinhava com o ciclo real de coleta da ANP e gerava
  ~7.9% dos grupos cnpj+semana com mais de 1 data de coleta distinta. Com
  semana de calendario isso cai pra 1 caso residual (ver abaixo).
- **Chave de join = CNPJ so digitos (`cnpj_chave`).** `petjua$CNPJ` vem so com
  digitos; `postos_2026_01$cnpj_revenda` vem formatado (`01.492.748/0003-83`).
  Ambos sao normalizados com `gsub("[^0-9]", "", ...)` antes do join.
- **`postos_2026_01`: `distinct()` logo apos o filtro de 2026 (2026-08-11).**
  O CSV bruto tem linhas 100% duplicadas (todas as colunas iguais, inclusive
  `data_coleta`) — problema de qualidade do dado da fonte, nao coletas
  distintas. Verificado programaticamente que isso e isolado a 1 unico cnpj
  na base inteira (`07663077000190`, 6 linhas removidas — 3 produtos x 2
  datas, semana 8). `distinct()` e seguro de aplicar globalmente.
- **`postos_wide`: painel cnpj+semana, 1 linha por combinacao (verificado
  2026-08-06).** Confirmado programaticamente que `cnpj_chave` + `semana`
  identifica unicamente as linhas — 0 duplicatas em 112.587 linhas.
  `values_fn = mean` no `pivot_wider` cobre o caso de 2 coletas do mesmo
  produto na mesma semana; isso acontece 1 vez na base atual (cnpj
  `07663077000190`, semana 8, datas 16/02 e 18/02 — coletas distintas e
  legitimas, diferente da duplicacao de linhas tratada acima), mas com
  valores identicos nas duas coletas, entao a media nao distorce nada.
- **`petjua_wide`: so Produto/Tancagem/Qtde de Bico variam dentro de um cnpj**
  (endereco, razao social, coordenadas etc. sao constantes por posto), entao
  so essas 3 colunas sao espalhadas por Produto; o resto fica como id_cols.
- **Merge da PMPF do etanol usa chave UF + semana, nao so semana.** BA e PE
  tem os dois uma linha por semana de vigencia; sem o UF, um posto de
  Juazeiro(BA) casaria tambem com o valor de PE na mesma semana.
- **Mudanca de PMPF detectada comparando com a vigencia anterior do mesmo
  estado** (`lag(Valor)` dentro de `group_by(UF)`), nao pela coluna
  "Alterado (*)" da planilha CONFAZ — essa coluna nao bate de forma
  consistente com a serie de valores.

## Limpeza do script (2026-08-06)

- Removidos os `cat()`/`print()` puramente diagnosticos (contagem de linhas
  no filtro de 2026, bloco inteiro "Diagnostico do join", bloco "diagnostico
  do merge com a PMPF do etanol" — contagens de NA, distribuicao de semanas
  casadas por posto, checagem de cnpjs sem preco).
- Mantidos os `cat()`/`print()` que sao o resultado da analise em si: a serie
  completa de PMPF do etanol (AEHC) em BA/PE e a tabela so das mudancas de
  preco — esse e o objetivo do script (secao "Mudancas na PMPF do etanol
  (AEHC) em BA e PE").

## Painel final para o RDD espacial (2026-08-13)

- **Objetivo do painel:** RDD espacial usando distancia como running
  variable. `painel_rdd` (cnpj_chave x semana) traz `valor_ETANOL`,
  `Latitude`/`Longitude` (constantes por posto, vem de `petjua_wide`),
  `pmpf_etanol` e as demais series de preco como placebo.
  **Falta ainda a running variable em si** (distancia a alguma referencia
  espacial - fronteira estadual BA/PE, rio Sao Francisco ou ponte
  Juazeiro-Petrolina) - nao foi calculada porque a escolha da referencia
  muda o desenho do RDD; decisao pendente com o usuario.
- **`pmpf_etanol` preenchido por LOCF (nao por join direto na semana da
  vigencia).** `etanol_ba_pe` so tem 1 linha por vigencia (troca de preco); a
  versao antiga do merge (`by = c("UF","semana")` direto contra
  `etanol_ba_pe`) so preenchia `pmpf_etanol` na semana exata em que a
  vigencia comecava, deixando todas as outras semanas com NA - inutil pro
  painel. Agora: `calendario_semanas` da a data de inicio (domingo) de cada
  semana de calendario do ano inteiro (independente de haver coleta de preco
  naquela semana); pra cada UF x semana, pega a vigencia mais recente com
  `Data Vigência <= semana_data_inicio` (`crossing()` + `filter()` +
  `slice_max()`, que funciona como um "asof join" manual). Semanas antes da
  primeira vigencia registrada ficam com `pmpf_etanol = NA` (correto - ainda
  nao ha PMPF conhecida).
- **`mudou_pmpf_etanol` e `variacao_pmpf_etanol` recalculados no painel
  semanal, nao mais copiados direto de `etanol_ba_pe`.** Sao `lag()` dentro
  de `group_by(UF)` no proprio `pmpf_etanol_semana`, pra distinguir "semana
  em que a vigencia mudou de fato" (`mudou_pmpf_etanol = TRUE`,
  `variacao_pmpf_etanol` = salto real) de "semana carregada por LOCF"
  (`mudou_pmpf_etanol = FALSE`, `variacao_pmpf_etanol = 0`).
- **Series de placebo (`valor_GASOLINA`, `valor_GASOLINA_ADITIVADA`,
  `valor_DIESEL`, `valor_DIESEL_S10`) incluidas no painel.** A PMPF que muda
  e' so a do etanol (AEHC); se o RDD achar descontinuidade nessas outras
  series na mesma fronteira/semana, e' sinal de efeito de fronteira geral
  (ex. tributacao estadual, custo logistico) em vez de um efeito especifico
  da PMPF do etanol - util como teste de falsificacao.
- **Nomes de coluna verificados rodando o pipeline (nao assumidos):**
  `Produto` em `postos_2026_01.csv` usa `"ETANOL"`, `"GASOLINA"`,
  `"GASOLINA ADITIVADA"`, `"DIESEL"`, `"DIESEL S10"` (vocabulario simples,
  diferente do `Produto` do cadastro `petjua`, que usa nomes longos tipo
  `"ETANOL HIDRATADO COMUM"`). `petjua` tem duas colunas de coordenadas -
  `Latitude`/`Longitude` (numericas, decimais, datum SIRGAS2000) e
  `Latitude (ANP4C)`/`Longitude (ANP4C)` (texto, formato DMS) - o painel usa
  as numericas. `MUNICÍPIO` vira `MUNIC_PIO` apos o
  `str_replace_all(names(...), "[^A-Za-z0-9]+", "_")` de `petjua_wide`
  (o "Í" acentuado e' o unico caractere fora de `[A-Za-z0-9]`).
- **Removidos os `cat()`/`print()` da secao de mudancas de PMPF do etanol**
  (impressao de `etanol_ba_pe` e `mudancas_etanol_ba_pe` no console) - isso
  reverte a decisao anterior de manter esses prints como "resultado da
  analise". `etanol_ba_pe` e `mudancas_etanol_ba_pe` continuam calculados
  normalmente no script, so nao sao mais impressos automaticamente; inspecionar
  direto no ambiente (ex. `View()`) quando precisar.

## Coisas a saber (edge cases de dados)

- CNPJ `07663077000190`, semana 8: 2 datas de coleta distintas (16/02 e
  18/02) para o mesmo cnpj+semana. As linhas duplicadas no CSV bruto (cada
  data aparecia 2x com valor identico) ja sao removidas pelo `distinct()`
  logo apos o filtro de 2026; o que sobra sao as 2 coletas legitimas da
  semana. Nao afeta o resultado porque os valores sao iguais nas duas datas,
  mas se aparecer um caso novo com valores *diferentes* entre datas da mesma
  semana, o `mean()` do `pivot_wider` vai silenciosamente medir os dois —
  vale checar `datas_semana` (min/max) se a media parecer estranha.

## Como manter este arquivo

Atualizar quando uma decisao de modelagem/limpeza de dados for tomada e o
motivo nao for obvio so lendo o codigo — nao duplicar coisas que ja estao
claras nos comentarios do `main.R` linha a linha.
