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
- **No painel semanal de `main.R`, o merge da PMPF do etanol usa UF + semana,
  nao so semana.** BA e PE tem os dois uma linha por semana de vigencia; sem o
  UF, um posto de Juazeiro(BA) casaria tambem com o valor de PE na mesma semana.
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
  `pmpf_etanol` e as demais series de preco como placebo. Para exploracao,
  `01_data_structure.R` calcula em `df` a distancia Haversine, em metros, de
  cada posto ao ponto de referencia latitude -9.4056 e longitude -40.5044;
  como `df` e posto x semana, a distancia se repete nas semanas do mesmo
  posto. A incorporacao dessa medida em `painel_rdd`/`main.R` e a interpretacao
  substantiva do ponto de referencia ainda precisam ser definidas antes da
  estimacao final.
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

## PMPF completada e auditada contra o DOU (2026-09-17)

- **`PMPF_2026_CONFAZ.xlsx` foi reconstruida a partir dos PDFs do DOU e agora
  tem 15 vigencias (01/01 a 01/08/2026), nao 11.** Faltavam `2026-01-01`,
  `2026-02-01`, `2026-03-01` e `2026-08-01` (a planilha as marcava como
  "NAO recuperado"). O pipeline em `pmpf_confaz/` faz o download, a extracao e
  a auditoria; ver `pmpf_confaz/README.md`. Backup do arquivo antigo em
  `PMPF_2026_CONFAZ_backup_<data>.xlsx`. **O `main.R` nao precisou de nenhuma
  mudanca** - o LOCF de `pmpf_etanol_semana` absorve as vigencias novas
  automaticamente.
- **As duas primeiras mudancas registradas de PMPF do etanol em PE estavam
  datadas ~15 dias tarde.** A fonte registra 01/02 (4,48 -> 4,92) e 01/03
  (4,92 -> 5,18), nao 16/02 e 16/03 como a versao antiga sugeria - a planilha
  simplesmente nao tinha as vigencias de 01/02 e 01/03, e o LOCF carregava o
  valor velho. Para a estimacao em `01_data_structure.R`, a segunda mudanca e
  considerada somente em 05/03, conforme a decisao registrada abaixo.
  Efeito no painel semanal: **9 das 26 semanas com coleta de preco (jan-jun)
  tinham `pmpf_etanol` errado ou ausente para PE** - semanas 1, 2 e 3 estavam
  `NA` (agora 4,48) e as semanas 6, 7, 8, 10, 11 e 12 carregavam valor
  defasado. A semana em que `mudou_pmpf_etanol` fica TRUE muda de 9 para 6 e
  de 13 para 10.
- **BA nunca muda a PMPF do etanol em 2026** (4,5900 em todas as 15
  vigencias, de 01/01 a 01/08). Confirmado no DOU, nao e' artefato de dado
  faltante. Ou seja, BA e' controle nunca-tratado e toda a variacao de PMPF do
  desenho vem de PE.
- **A PMPF de PE em 01/03/2026 saiu errada no DOU e foi retificada 4 dias
  depois da vigencia comecar.** O Ato 5 (DOU 25/02) publicou `PE 4,9200`
  (sem asterisco, ou seja, "sem mudanca"); a retificacao do DOU de
  **05/03/2026** trocou para `*5,1800`. A planilha grava 5,1800 (valor valido,
  seguindo a convencao que ela ja usava de aplicar correcoes) e registra o
  4,9200 na aba "Correcoes Aplicadas". **Decisao metodologica tomada em
  2026-09-20:** `01_data_structure.R` mantem 4,9200 ate 04/03 e passa a usar
  5,1800 somente em 05/03, quando a retificacao foi publicada. Nao e mantida
  uma especificacao alternativa com mudanca em 01/03.
- **Fonte = PDF do DOU; a pagina HTML do CONFAZ nao e' confiavel para copiar
  valores.** Ela consolida correcoes posteriores sem avisar e, na conferencia,
  devolveu numeros divergentes do DOU em pelo menos 3 atos (7, 5 e 2 - detalhe
  em `pmpf_confaz/README.md`). Sete PDFs (Ato 31/2025 e Atos 1-5 e 20/2026)
  sao imagem, sem camada de texto, e estao transcritos a mao em
  `pmpf_confaz/transcricoes_dou.csv`.
- **A vigencia de 01/01/2026 vem do Ato COTEPE/PMPF 31/2025** (DOU
  24/12/2025), porque a numeracao dos atos reinicia a cada ano e o primeiro
  ato de 2026 so vale a partir de 16/01. Consequencia: na aba "Painel PMPF
  2026" a coluna `Ato Base` vale 31 nessa vigencia e se refere a um ato de
  **2025** - `Ato Base` sozinho nao identifica o ato, precisa do ano (a aba
  "Metadados Atos" tem a coluna `Ano`). O `main.R` nao usa `Ato Base`.
- **Auditoria das 11 vigencias que ja existiam: 638 celulas conferidas, zero
  divergencia de valor.** Os numeros que ja estavam na planilha estavam
  corretos. As unicas divergencias (17) foram nas colunas `Alterado (*)` /
  `Redução (**)`, todas em celulas corrigidas por ato posterior, onde a versao
  antiga aplicava o valor novo mas deixava a marcacao vazia. **Esse era o
  motivo de a coluna "Alterado (*)" nao bater com a serie de valores** (ver
  decisao acima sobre usar `lag(Valor)`). As marcacoes agora estao completas,
  mas **manter o `lag(Valor)` no `main.R`**: ele independe de a fonte marcar
  corretamente e ja esta validado.
- **No painel semanal de `main.R`, cuidado ao datar eventos: o LOCF usa o
  domingo de inicio da semana.** Quando uma vigencia comeca no meio da semana,
  `mudou_pmpf_etanol` fica TRUE na semana *seguinte*. Ex.: a vigencia de 01/04
  (quarta) cai na semana 14, mas o painel marca a mudanca na semana 15, e a
  semana 14 inteira fica com o valor antigo mesmo que 01-04/04 ja estivessem no
  valor novo. Na fonte, as datas de PE de 01/02 e 01/03 caem em domingos; esse
  comentario descreve apenas o painel semanal legado de `main.R`. No RDD de
  `01_data_structure.R`, a mudanca de marco e datada em 05/03.

## Join exato da PMPF e estimacoes em `01_data_structure.R` (2026-09-19)

- **Em `df`, a PMPF passa a ser associada pela data exata da coleta.** O join
  usa `UF` e a vigencia mais recente que satisfaz
  `data_vigencia <= data_coleta` (`join_by()` com `closest()`). As tabelas de
  PMPF nao sao mais expandidas artificialmente por semana antes desse join.
  Isso preserva as 531 linhas, sem PMPF ausente, vigencia futura ou duplicata
  em `cnpj_chave x semana`.
- **A correcao altera 66 observacoes que o metodo semanal antecipava:** 16 em
  02-04/03 (5,18 -> 4,92), 16 em 30/03 (5,43 -> 5,18), 17 em 27-28/04
  (5,66 -> 5,43) e 17 em 29-30/06 (5,42 -> 5,57). Essa comparacao foi feita
  durante a validacao da mudanca; o bloco temporario de auditoria nao permanece
  no script analitico.
- **`df_rdd` e uma base derivada; `df` permanece intacto.** A distancia ao
  ponto da ponte e positiva em PE e negativa na BA. A distancia e running
  variable/controle espacial, nao instrumento. O suporte atual e de 2 BA/10 PE
  ate 3 km, 4 BA/17 PE ate 5 km, 6 BA/21 PE ate 10 km e 7 BA/21 PE na amostra
  completa; por isso, 10 km e o bandwidth principal.
- **Modelo continuo:** usa todas as mudancas da PMPF de PE, efeitos fixos de
  posto e semana e interacoes do choque com a distancia assinada. Os erros
  padrao principais sao agrupados por posto; Driscoll-Kraay e apresentado como
  robustez. Ha resultados para 3 km, 5 km, 10 km e amostra completa.
- **Modelos por evento:** para fevereiro, marco, abril, maio e junho, o
  instrumento e `tratado_pe x pos_evento` e o PMPF e o regressor instrumentado.
  Cada janela inclui o mes anterior e o mes do evento, dentro de 10 km, e o
  pos-evento usa a data exata da coleta. Como a mudanca da PMPF e determinada
  pelo instrumento dentro de cada janela, esses resultados sao razoes de Wald,
  nao um LATE classico de compliers; o F do primeiro estagio tende ao infinito
  e nao e informativo. Para marco, a unica data de mudanca usada e 05/03,
  quando a retificacao com o valor 5,18 foi publicada.
- **Interpretacao:** o coeficiente mede repasse local da PMPF sob a hipotese de
  que nao houve outros choques especificos de PE nas mesmas datas. Possiveis
  respostas dos precos de Juazeiro ao deslocamento de consumidores contaminam
  o controle e devem ser discutidas como spillover. A inferencia tambem exige
  cautela: ha somente 28 postos (7 BA e 21 PE) e apenas duas jurisdicoes de
  politica.

## Coisas a saber (edge cases de dados)

- CNPJ `07663077000190`, semana 8: 2 datas de coleta distintas (16/02 e
  18/02) para o mesmo cnpj+semana. As linhas duplicadas no CSV bruto (cada
  data aparecia 2x com valor identico) ja sao removidas pelo `distinct()`
  logo apos o filtro de 2026; o que sobra sao as 2 coletas legitimas da
  semana. Nao afeta o resultado porque os valores sao iguais nas duas datas,
  mas se aparecer um caso novo com valores *diferentes* entre datas da mesma
  semana, o `mean()` do `pivot_wider` vai silenciosamente medir os dois —
  vale checar `datas_semana` (min/max) se a media parecer estranha.

- **Filtrar `petjua` por um produto especifico perde postos.** `petjua` e
  cnpj x Produto (652 linhas, 145 postos) e nao todo posto tem linha de cada
  produto: so 108 dos 145 tem `"ETANOL HIDRATADO COMUM"` — dos 37 restantes, 8
  tem so `"ETANOL HIDRATADO ADITIVADO"` e 29 nao tem etanol nenhum (verificado
  2026-09-18). Depois desse filtro `cnpj_chave` e' unico
  (1 linha por posto), mas 37 postos ficam de fora — entao **nao use um filtro
  de produto para montar tabela de coordenadas/endereco**; essas colunas sao
  constantes por posto e o `pivot_wider` de `petjua_wide` as preserva para os
  145. Alem disso, 1 dos 108 postos esta sem `Latitude`/`Longitude`.

## Como manter este arquivo

Atualizar quando uma decisao de modelagem/limpeza de dados for tomada e o
motivo nao for obvio so lendo o codigo — nao duplicar coisas que ja estao
claras nos comentarios do `main.R` linha a linha.
