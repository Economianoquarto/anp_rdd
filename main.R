rm(list=ls()) 
gc()

library(readr)
library(readxl)
library(tidyverse)

# Semana de calendario (domingo a sabado), nao bloco fixo de 7 dias a partir
# de 01/01: ex. em 2026 (que comeca numa quinta) a semana 1 vai so ate
# 03/01 (dom-sab anteriores), a semana 2 vai de 04/01 (domingo) a 10/01.
semana_calendario <- function(data) as.integer(format(data, "%U")) + 1L

nomes_colunas <- c("regiao_sigla", "estado_sigla", "municipio", "revenda",
                    "cnpj_revenda", "rua", "numero_rua", "complemento",
                    "bairro", "cep", "produto", "data_coleta",
                    "valor_venda", "valor_compra", "unidade_medida", "bandeira")

postos_2026_01 <- read_delim("postos_2026_01.csv",
                         delim = ";", escape_double = FALSE,
                         col_names = nomes_colunas, skip = 1,
                         col_types = cols(
                           regiao_sigla   = col_character(),
                           estado_sigla   = col_character(),
                           municipio      = col_character(),
                           revenda        = col_character(),
                           cnpj_revenda   = col_character(),
                           rua            = col_character(),
                           numero_rua     = col_character(),
                           complemento    = col_character(),
                           bairro         = col_character(),
                           cep            = col_character(),
                           produto        = col_character(),
                           data_coleta    = col_date(format = "%d/%m/%Y"),
                           valor_venda    = col_double(),
                           valor_compra   = col_double(),
                           unidade_medida = col_character(),
                           bandeira       = col_character()
                         ),
                         locale = locale(decimal_mark = ",", encoding = "UTF-8"),
                         trim_ws = TRUE)

juazeiro <- read_excel("juazeiro.xlsx")
petrolina <- read_excel("petrolina.xlsx")

petjua <- bind_rows(juazeiro, petrolina)

# CNPJ vem em formatos diferentes nas duas bases (petjua: so digitos, ex.
# "02707872000110"; postos_2026_01: com pontuacao, ex. "01.492.748/0003-83"),
# entao precisa limpar a pontuacao antes de usar como chave de join.
petjua$cnpj_chave <- gsub("[^0-9]", "", petjua$CNPJ)
postos_2026_01$cnpj_chave <- gsub("[^0-9]", "", postos_2026_01$cnpj_revenda)

# Mantem so observacoes cuja data da coleta caiu de fato em 2026.
postos_2026_01 <- postos_2026_01 %>% filter(year(data_coleta) == 2026)

# Remove linhas 100% duplicadas (todas as colunas iguais, inclusive
# data_coleta) - problema de qualidade do CSV bruto, nao coletas distintas
# (afeta o cnpj 07663077000190, semana 8: 3 produtos x 2 datas = 6 linhas).
postos_2026_01 <- postos_2026_01 %>% distinct()

# Semana de calendario da coleta, para manter a variacao temporal em vez de
# colapsar tudo no periodo.
postos_2026_01$semana <- semana_calendario(postos_2026_01$data_coleta)

postos_2026_01 %>%
  group_by(cnpj_chave, semana, produto) %>%
  summarise(n_linhas  = n(),
            n_datas   = n_distinct(data_coleta),
            n_valores = n_distinct(valor_venda),
            .groups = "drop") %>%
  filter(n_linhas > 1) %>%
  as.data.frame()

datas_semana <- postos_2026_01 %>%
  group_by(cnpj_chave, semana) %>%
  summarise(data_coleta_min = min(data_coleta),
            data_coleta_max = max(data_coleta),
            .groups = "drop")
 

# Painel cnpj-semana: cada linha e um cnpj em uma semana (cnpj_chave + semana
# identifica unicamente as linhas de postos_wide). values_fn = mean cobre o
# caso de 2 coletas do mesmo produto na mesma semana de calendario - acontece
# no cnpj 07663077000190 (semana 8, datas 16/02 e 18/02), mas os valores sao
# identicos nas duas coletas, entao a media nao altera o resultado.
postos_wide <- postos_2026_01 %>%
  select(cnpj_chave, semana, produto, valor_venda) %>%
  pivot_wider(id_cols = c(cnpj_chave, semana), names_from = produto,
              values_from = valor_venda, values_fn = mean, names_prefix = "valor_") %>%
  left_join(datas_semana, by = c("cnpj_chave", "semana"))
names(postos_wide) <- str_replace_all(names(postos_wide), " ", "_")

# Em petjua, so Produto/Tancagem/Qtde de Bico variam dentro de um mesmo cnpj
# (endereco, razao social, coordenadas etc. sao constantes por posto), entao
# da pra manter todo o resto como id_cols e so espalhar essas tres por Produto.
petjua_wide <- petjua %>%
  pivot_wider(names_from = Produto,
              values_from = c(`Tancagem (m³)`, `Qtde de Bico`))
names(petjua_wide) <- str_replace_all(names(petjua_wide), "[^A-Za-z0-9]+", "_")

petjua_postos <- left_join(petjua_wide, postos_wide, by = "cnpj_chave")

# --- Mudancas na PMPF do etanol (AEHC) em BA e PE ---
pmpf_confaz <- read_excel("PMPF_2026_CONFAZ.xlsx", sheet = "Painel PMPF 2026")

# Comparo cada vigencia com a vigencia anterior do MESMO estado para achar
# onde o valor da PMPF realmente mudou (nao uso a coluna "Alterado (*)" da
# planilha porque ela nao bate de forma consistente com a serie de valores).
etanol_ba_pe <- pmpf_confaz %>%
  filter(Combustível == "AEHC", UF %in% c("BA", "PE")) %>%
  mutate(`Data Vigência` = as.Date(`Data Vigência`),
         semana = semana_calendario(`Data Vigência`)) %>%
  arrange(UF, `Data Vigência`) %>%
  group_by(UF) %>%
  mutate(valor_anterior = lag(Valor),
         variacao = Valor - valor_anterior,
         mudou = !is.na(variacao) & variacao != 0) %>%
  ungroup()

mudancas_etanol_ba_pe <- etanol_ba_pe %>% filter(mudou)

# --- PMPF do etanol por semana, preenchida por LOCF ---
# etanol_ba_pe tem 1 linha por VIGENCIA (troca de preco). Pra ter o valor
# vigente em toda semana do painel - nao so na semana em que a vigencia
# comecou -, propago o ultimo valor conhecido (LOCF) semana a semana, usando
# a data de inicio de cada semana de calendario como referencia: uma
# vigencia pode comecar no meio de uma semana, entao o numero da semana
# sozinho nao basta como referencia temporal.

# Data de inicio (domingo) de cada semana de calendario do ano - independe de
# haver ou nao coleta de preco naquela semana, e cobre o ano inteiro pra nao
# perder vigencias fora do intervalo observado em postos_2026_01.
calendario_semanas <- tibble(data = seq(as.Date("2026-01-01"), as.Date("2026-12-31"), by = "day")) %>%
  mutate(semana = semana_calendario(data)) %>%
  group_by(semana) %>%
  summarise(semana_data_inicio = min(data), .groups = "drop")

# Pra cada UF x semana, pego a vigencia mais recente com
# Data Vigencia <= inicio da semana (isso e o LOCF). Semanas anteriores a
# primeira vigencia registrada ficam sem match (pmpf_etanol = NA) - correto,
# pois ainda nao ha PMPF conhecida nesse ponto.
# (O left_join gera varias linhas por UF+semana antes do filtro/slice_max -
# esperado, e' resolvido logo em seguida.)
pmpf_etanol_semana <- crossing(UF = c("BA", "PE"), calendario_semanas) %>%
  left_join(etanol_ba_pe %>% select(UF, `Data Vigência`, Valor), by = "UF") %>%
  filter(`Data Vigência` <= semana_data_inicio) %>%
  group_by(UF, semana) %>%
  slice_max(`Data Vigência`, n = 1, with_ties = FALSE) %>%
  ungroup() %>%
  arrange(UF, semana) %>%
  rename(pmpf_etanol = Valor, data_vigencia_pmpf_etanol = `Data Vigência`) %>%
  group_by(UF) %>%
  mutate(
    # TRUE so na semana em que a vigencia realmente mudou (nao em toda
    # semana carregada por LOCF).
    mudou_pmpf_etanol    = !is.na(lag(data_vigencia_pmpf_etanol)) &
                              data_vigencia_pmpf_etanol != lag(data_vigencia_pmpf_etanol),
    # Diferenca vs a semana anterior: 0 nas semanas so-LOCF, igual ao salto
    # real na semana da mudanca - fica pronto pra usar como marcador de
    # evento no RDD.
    variacao_pmpf_etanol = pmpf_etanol - lag(pmpf_etanol)
  ) %>%
  ungroup()

# So "semana" nao basta como chave sozinha no join com petjua_postos: BA e PE
# tem os dois uma linha por semana, e sem o UF um posto de Juazeiro(BA)
# acabaria casando tambem com o valor de PE na mesma semana.
petjua_postos <- left_join(petjua_postos, pmpf_etanol_semana, by = c("UF", "semana"))

# --- Painel final ID (cnpj) x semana pro RDD espacial ---
# valor_GASOLINA/_ADITIVADA/_DIESEL/_DIESEL_S10 entram como series de placebo:
# a PMPF que muda e' so a do etanol (AEHC), entao o preco desses outros
# produtos nao deveria "descontinuar" na mesma semana/fronteira se o efeito
# encontrado for mesmo da PMPF do etanol e nao um efeito de fronteira geral.
painel_rdd <- petjua_postos %>%
  select(
    cnpj_chave, semana,
    UF, MUNIC_PIO,
    Latitude, Longitude,
    valor_ETANOL,
    valor_GASOLINA, valor_GASOLINA_ADITIVADA, valor_DIESEL, valor_DIESEL_S10,
    pmpf_etanol, data_vigencia_pmpf_etanol, variacao_pmpf_etanol, mudou_pmpf_etanol,
    data_coleta_min, data_coleta_max
  ) %>%
  arrange(cnpj_chave, semana)


