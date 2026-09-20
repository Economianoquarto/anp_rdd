rm(list=ls())
gc()

library(readr)
library(readxl)
library(tidyverse)

## Base postos
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

# limpar a pontuacao antes de usar como chave de join
postos_2026_01$cnpj_chave <- gsub("[^0-9]", "", postos_2026_01$cnpj_revenda)

range(postos_2026_01$data_coleta)

postos_2026_et_peju <- postos_2026_01 |>
      filter(municipio %in% c("PETROLINA", "JUAZEIRO"),
              produto == "ETANOL") |>
      select(municipio,
             cnpj_chave,
             data_coleta,
             valor_venda,
             unidade_medida,
             bandeira,
             rua,
             numero_rua,
             complemento,
             bairro,
             cep)

postos_2026_et_peju$semana <- floor_date(postos_2026_et_peju$data_coleta, unit = "week", week_start = 7)   # 7 = domingo
range(postos_2026_et_peju$semana)

postos_2026_et_peju %>%
  group_by(cnpj_chave, semana) %>%
  summarise(n_linhas  = n(),
            n_datas   = n_distinct(data_coleta),
            n_valores = n_distinct(valor_venda),
            .groups = "drop") %>%
  filter(n_linhas > 1) %>%
  as.data.frame()

## Base i-simp localizacao
juazeiro <- read_excel("juazeiro.xlsx")
petrolina <- read_excel("petrolina.xlsx")

petjua <- bind_rows(juazeiro, petrolina)
petjua$cnpj_chave <- gsub("[^0-9]", "", petjua$CNPJ)

petjua_et <- petjua |>
      filter(Produto == "ETANOL HIDRATADO COMUM") |>
      select(municipio = `MUNICÍPIO`,
             cnpj_chave,
             Latitude,
             Longitude,
             produto = Produto,
             UF,
             bairro = BAIRRO)|>
      as.data.frame()

## Juntando as bases de preços e localização

petjua_postos <- inner_join(postos_2026_et_peju, petjua_et, by = c("cnpj_chave","bairro","municipio"))

## Base de PMPF
# Mudancas na PMPF do etanol (AEHC) em BA e PE
pmpf_confaz <- read_excel("PMPF_2026_CONFAZ.xlsx", sheet = "Painel PMPF 2026")

etanol_ba_pe <- pmpf_confaz %>%
  filter(Combustível == "AEHC", UF %in% c("BA", "PE")) |>
  transmute(
    UF,
    # O valor corrigido de PE para marco passou a ser observado em 05/03,
    # data da publicacao da retificacao, e nao em 01/03.
    data_vigencia = if_else(
      UF == "PE" & as.Date(`Data Vigência`) == as.Date("2026-03-01"),
      as.Date("2026-03-05"),
      as.Date(`Data Vigência`)
    ),
    pmpf = Valor
  ) |>
  arrange(UF, data_vigencia)

range(etanol_ba_pe$data_vigencia)

petjua_postos <- petjua_postos %>%
  mutate(
    semana = as.integer(data_coleta - as.Date("2026-01-04")) %/% 7L + 1L
  )

range(petjua_postos$semana, na.rm = TRUE)

# Cada coleta recebe a vigencia mais recente do mesmo estado cuja data nao
# ultrapassa a data da coleta. Isso evita antecipar mudancas no meio da semana.
duplicatas_vigencia <- etanol_ba_pe %>%
  count(UF, data_vigencia) %>%
  filter(n > 1)

stopifnot(nrow(duplicatas_vigencia) == 0)

n_linhas_petjua_postos <- nrow(petjua_postos)

df <- petjua_postos %>%
  left_join(
    etanol_ba_pe,
    by = join_by(
      UF,
      closest(data_coleta >= data_vigencia)
    ),
    relationship = "many-to-one"
  )

# Distancia em linha reta entre cada posto e o ponto de referencia.
# geosphere usa a ordem longitude/latitude e retorna a distancia em metros.
df <- df %>%
  mutate(
    distancia_m = geosphere::distHaversine(
      p1 = cbind(Longitude, Latitude),
      p2 = c(-40.5044, -9.4056)
    )
  )

# Verificacoes da unidade posto-semana e do rolling join da PMPF.
verificacao_pmpf_ausente <- df %>%
  filter(is.na(pmpf))

verificacao_vigencia_posterior <- df %>%
  filter(data_vigencia > data_coleta)

verificacao_duplicata_posto_semana <- df %>%
  count(cnpj_chave, semana) %>%
  filter(n > 1)

stopifnot(
  nrow(df) == n_linhas_petjua_postos,
  nrow(verificacao_pmpf_ausente) == 0,
  nrow(verificacao_vigencia_posterior) == 0,
  nrow(verificacao_duplicata_posto_semana) == 0
)

summary(df$distancia_m)

postos_sem_distancia <- df %>%
  filter(is.na(distancia_m)) %>%
  select(cnpj_chave, Latitude, Longitude) %>%
  distinct()

stopifnot(nrow(postos_sem_distancia) == 0)

# --- Base para o RDD espacial ---
# A distancia e positiva em Petrolina e negativa em Juazeiro. Ela entra como
# running variable/controle espacial; nao e usada como instrumento.
pmpf_pe_vigencias <- etanol_ba_pe %>%
  filter(UF == "PE") %>%
  transmute(
    data_vigencia_pe = data_vigencia,
    pmpf_pe_vigente = pmpf
  )

df_rdd <- df %>%
  left_join(
    pmpf_pe_vigencias,
    by = join_by(closest(data_coleta >= data_vigencia_pe)),
    relationship = "many-to-one"
  ) %>%
  mutate(
    tratado_pe = as.integer(UF == "PE"),
    distancia_assinada_km = if_else(
      UF == "PE",
      distancia_m / 1000,
      -distancia_m / 1000
    ),
    choque_pmpf_pe = pmpf_pe_vigente - 4.48,
    exposicao_pmpf = tratado_pe * choque_pmpf_pe
  )

stopifnot(
  nrow(df_rdd) == nrow(df),
  !anyNA(df_rdd$pmpf_pe_vigente)
)

# Numero de postos efetivamente disponiveis de cada lado em cada bandwidth.
postos_distancia <- df_rdd %>%
  distinct(cnpj_chave, UF, distancia_assinada_km)

suporte_bandwidth <- bind_rows(
  postos_distancia %>%
    filter(abs(distancia_assinada_km) <= 3) %>%
    count(UF, name = "n_postos") %>%
    mutate(bandwidth = "3 km"),
  postos_distancia %>%
    filter(abs(distancia_assinada_km) <= 5) %>%
    count(UF, name = "n_postos") %>%
    mutate(bandwidth = "5 km"),
  postos_distancia %>%
    filter(abs(distancia_assinada_km) <= 10) %>%
    count(UF, name = "n_postos") %>%
    mutate(bandwidth = "10 km"),
  postos_distancia %>%
    count(UF, name = "n_postos") %>%
    mutate(bandwidth = "completa")
) %>%
  select(bandwidth, UF, n_postos)

# --- Modelo continuo: repasse medio de todas as mudancas da PMPF ---
# O coeficiente de exposicao_pmpf mede o repasse na ponte. As interacoes
# permitem que a evolucao espacial seja diferente nos dois lados.
formula_modelo_continuo <-
  valor_venda ~
    exposicao_pmpf +
    choque_pmpf_pe:distancia_assinada_km +
    exposicao_pmpf:distancia_assinada_km |
    cnpj_chave + semana

modelo_continuo_3km <- fixest::feols(
  formula_modelo_continuo,
  data = df_rdd %>% filter(abs(distancia_assinada_km) <= 3),
  cluster = ~cnpj_chave
)

modelo_continuo_5km <- fixest::feols(
  formula_modelo_continuo,
  data = df_rdd %>% filter(abs(distancia_assinada_km) <= 5),
  cluster = ~cnpj_chave
)

# Especificacao principal: menor bandwidth com pelo menos 5 postos por lado.
modelo_continuo_10km <- fixest::feols(
  formula_modelo_continuo,
  data = df_rdd %>% filter(abs(distancia_assinada_km) <= 10),
  cluster = ~cnpj_chave
)

modelo_continuo_completo <- fixest::feols(
  formula_modelo_continuo,
  data = df_rdd,
  cluster = ~cnpj_chave
)

# Sensibilidade da inferencia a dependencia temporal e espacial.
modelo_continuo_10km_dk <- fixest::feols(
  formula_modelo_continuo,
  data = df_rdd %>% filter(abs(distancia_assinada_km) <= 10),
  vcov = fixest::vcov_DK(~semana)
)

tabela_modelos_continuos <- fixest::etable(
  "3 km" = modelo_continuo_3km,
  "5 km" = modelo_continuo_5km,
  "10 km" = modelo_continuo_10km,
  "Amostra completa" = modelo_continuo_completo,
  "10 km - Driscoll-Kraay" = modelo_continuo_10km_dk,
  fitstat = ~n
)

# --- Mudancas individuais da PMPF: IV / razao de Wald ---
# Em cada janela, Petrolina x pos-evento instrumenta a PMPF vigente. A
# distancia continua sendo controle espacial e nao instrumento. Cada janela
# inclui o mes anterior e o mes em que a mudanca entrou em vigor.
formula_evento_iv <-
  valor_venda ~
    pos_evento:distancia_assinada_km +
    tratado_pe:pos_evento:distancia_assinada_km |
    cnpj_chave + semana |
    pmpf_modelo ~ instrumento_evento

formula_evento_reduzida <-
  valor_venda ~
    instrumento_evento +
    pos_evento:distancia_assinada_km +
    tratado_pe:pos_evento:distancia_assinada_km |
    cnpj_chave + semana

evento_fevereiro <- df_rdd %>%
  filter(
    data_coleta >= as.Date("2026-01-01"),
    data_coleta <= as.Date("2026-02-28"),
    abs(distancia_assinada_km) <= 10
  ) %>%
  mutate(
    pos_evento = as.integer(data_coleta >= as.Date("2026-02-01")),
    instrumento_evento = tratado_pe * pos_evento,
    pmpf_modelo = pmpf
  )

evento_marco <- df_rdd %>%
  filter(
    data_coleta >= as.Date("2026-02-01"),
    data_coleta <= as.Date("2026-03-31"),
    abs(distancia_assinada_km) <= 10
  ) %>%
  mutate(
    pos_evento = as.integer(data_coleta >= as.Date("2026-03-05")),
    instrumento_evento = tratado_pe * pos_evento,
    pmpf_modelo = pmpf
  )

evento_abril <- df_rdd %>%
  filter(
    data_coleta >= as.Date("2026-03-01"),
    data_coleta <= as.Date("2026-04-30"),
    abs(distancia_assinada_km) <= 10
  ) %>%
  mutate(
    pos_evento = as.integer(data_coleta >= as.Date("2026-04-01")),
    instrumento_evento = tratado_pe * pos_evento,
    pmpf_modelo = pmpf
  )

evento_maio <- df_rdd %>%
  filter(
    data_coleta >= as.Date("2026-04-01"),
    data_coleta <= as.Date("2026-05-31"),
    abs(distancia_assinada_km) <= 10
  ) %>%
  mutate(
    pos_evento = as.integer(data_coleta >= as.Date("2026-05-01")),
    instrumento_evento = tratado_pe * pos_evento,
    pmpf_modelo = pmpf
  )

evento_junho <- df_rdd %>%
  filter(
    data_coleta >= as.Date("2026-05-01"),
    data_coleta <= as.Date("2026-06-30"),
    abs(distancia_assinada_km) <= 10
  ) %>%
  mutate(
    pos_evento = as.integer(data_coleta >= as.Date("2026-06-01")),
    instrumento_evento = tratado_pe * pos_evento,
    pmpf_modelo = pmpf
  )

modelo_evento_fevereiro <- fixest::feols(
  formula_evento_iv, evento_fevereiro, cluster = ~cnpj_chave
)
modelo_evento_marco <- fixest::feols(
  formula_evento_iv, evento_marco, cluster = ~cnpj_chave
)
modelo_evento_abril <- fixest::feols(
  formula_evento_iv, evento_abril, cluster = ~cnpj_chave
)
modelo_evento_maio <- fixest::feols(
  formula_evento_iv, evento_maio, cluster = ~cnpj_chave
)
modelo_evento_junho <- fixest::feols(
  formula_evento_iv, evento_junho, cluster = ~cnpj_chave
)

# Primeiros estagios e formas reduzidas ficam disponiveis para conferir a
# decomposicao da razao de Wald.
primeiro_estagio_fevereiro <- summary(modelo_evento_fevereiro, stage = 1)
primeiro_estagio_marco <- summary(modelo_evento_marco, stage = 1)
primeiro_estagio_abril <- summary(modelo_evento_abril, stage = 1)
primeiro_estagio_maio <- summary(modelo_evento_maio, stage = 1)
primeiro_estagio_junho <- summary(modelo_evento_junho, stage = 1)

forma_reduzida_fevereiro <- fixest::feols(
  formula_evento_reduzida, evento_fevereiro, cluster = ~cnpj_chave
)
forma_reduzida_marco <- fixest::feols(
  formula_evento_reduzida, evento_marco, cluster = ~cnpj_chave
)
forma_reduzida_abril <- fixest::feols(
  formula_evento_reduzida, evento_abril, cluster = ~cnpj_chave
)
forma_reduzida_maio <- fixest::feols(
  formula_evento_reduzida, evento_maio, cluster = ~cnpj_chave
)
forma_reduzida_junho <- fixest::feols(
  formula_evento_reduzida, evento_junho, cluster = ~cnpj_chave
)

resumo_eventos <- tibble(
  evento = c("01/02", "05/03", "01/04", "01/05", "01/06"),
  primeiro_estagio = c(
    coef(primeiro_estagio_fevereiro)["instrumento_evento"],
    coef(primeiro_estagio_marco)["instrumento_evento"],
    coef(primeiro_estagio_abril)["instrumento_evento"],
    coef(primeiro_estagio_maio)["instrumento_evento"],
    coef(primeiro_estagio_junho)["instrumento_evento"]
  ),
  forma_reduzida = c(
    coef(forma_reduzida_fevereiro)["instrumento_evento"],
    coef(forma_reduzida_marco)["instrumento_evento"],
    coef(forma_reduzida_abril)["instrumento_evento"],
    coef(forma_reduzida_maio)["instrumento_evento"],
    coef(forma_reduzida_junho)["instrumento_evento"]
  ),
  razao_wald = forma_reduzida / primeiro_estagio,
  coeficiente_2sls = c(
    coef(modelo_evento_fevereiro)["fit_pmpf_modelo"],
    coef(modelo_evento_marco)["fit_pmpf_modelo"],
    coef(modelo_evento_abril)["fit_pmpf_modelo"],
    coef(modelo_evento_maio)["fit_pmpf_modelo"],
    coef(modelo_evento_junho)["fit_pmpf_modelo"]
  )
) %>%
  mutate(across(where(is.numeric), unname))

stopifnot(
  isTRUE(all.equal(
    resumo_eventos$razao_wald,
    resumo_eventos$coeficiente_2sls,
    tolerance = 1e-8
  ))
)

tabela_modelos_eventos <- fixest::etable(
  "Fevereiro" = modelo_evento_fevereiro,
  "Marco (05/03)" = modelo_evento_marco,
  "Abril" = modelo_evento_abril,
  "Maio" = modelo_evento_maio,
  "Junho" = modelo_evento_junho,
  fitstat = ~n
)

# O F do primeiro estagio nao e exibido: dentro de cada janela, a mudanca de
# PMPF e determinada exatamente por PE x pos-evento. Por isso, o F tende ao
# infinito e sua formatacao gera perda de precisao numerica. Os coeficientes
# dos primeiros estagios permanecem em resumo_eventos.
