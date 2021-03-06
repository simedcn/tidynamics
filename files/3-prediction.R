## ---- include = FALSE----------------------------------------------------
rm(list = ls())
knitr::opts_chunk$set(
  collapse = TRUE,
  comment = "#>",
  fig.align = "center",
  fig.asp = 9/16,
  fig.width = 7,
  warning = FALSE
)

## ---- message=FALSE------------------------------------------------------
library(tidyverse)
library(tidymodels)
library(magrittr)
library(ggplot2)
library(lubridate)
library(stringr)
library(splines)
library(glue)

files <- dir(
  "~/GitHub/tidynamics/vignettes/funcs/pred",
  full.names = TRUE
  )
for (i in 1:length(files)) {
  source(files[i])
}

## ------------------------------------------------------------------------
## The data is stored in list
li <- readRDS("~/GitHub/tidynamics/data/soenderborg.RDS")

## Change the column names in `li$Gnwp` like "k1" to "t1"
for (i in names(li$Gnwp)) {
  li$Gnwp[paste0("t", str_sub(i, 2, -1))] = li$Gnwp[i]
}


## ------------------------------------------------------------------------
#' Get the first character in the string
str_sub_1 <- function(chr){
  i <- NA
  if (str_sub(chr, 1, 1) == "k") {
    i <- "t_a.p"
  } else {
    i <- "g.p"
  }
  return(i)
}

#' Get the value of step ahead
get_ahead <- function(chr){
  return(strtoi(str_sub(chr, 2, -1)))
}

ti <- as_tibble(
    cbind(
      data.frame(
        "time" = li$t, "t_a" = li$Ta, "g" = li$G), li$Tanwp, li$Gnwp[, 50:98],
        "ph1" = li$Ph1, "ph2" = li$Ph2, "ph3" = li$Ph3
    )
  )

rm(li)

ti %>%  # Check if `time` is the primary key
  count(time) %>%
  {nrow(filter(., n > 1)) == 0}

li <- list()

li$time <- ti %>%
  mutate(at = 1:nrow(.)) %>%
  mutate(fo = 1:nrow(.)) %>%
  dplyr::select(at, fo, time)

li$obs <- ti %>%
  mutate(fo = 1:nrow(.)) %>%
  dplyr::select(fo, t_a, g, ph1, ph2, ph3)

li$pred <- ti %>%
  mutate(at = 1:nrow(.)) %>%
  dplyr::select(at, 4:90) %>%
  gather(-at, key = "ahead_chr", value = "pred") %>%
  mutate(whi = map_chr(ahead_chr, str_sub_1)) %>%
  mutate(ahead = map_int(ahead_chr, get_ahead)) %>%
  dplyr::select(-ahead_chr) %>%
  mutate(fo = at + ahead) %>%
  spread(key = whi, value = pred) %>%
  arrange(at)

# saveRDS(li, "~GitHub/tidynamics/data/soenderborg_tidy.RDS")

## ------------------------------------------------------------------------
li$pred %>%
  left_join(li$obs, by = "fo") %>%
  filter(ahead %in% c(1, 24)) %>%
  ggplot() +
    geom_point(mapping = aes(x = t_a, y = t_a.p, color = ahead)) +
    geom_abline(aes(intercept = 0, slope = 1), color = "red") +
    labs(
      title = "Obs, 1 and 24 Step Ahead Pred of Ambient Temp",
      x = "Observation (Celsius Degree)", y = "Prediction (Celsius Degree)"
      )

li$obs %>%
  left_join(li$time, by = "fo") %>%
  ggplot() +
  geom_line(mapping = aes(x = time, y = t_a)) +
  labs(
    title = "Obs of Ambient Temp",
    x = "Time (Day)", y = "Temp (Celsius Degree)"
  )

## ------------------------------------------------------------------------
#' Get recipe from split
get_li_dm_1 <- function(split, coef_t, coef_g) {
  rec <-
    training(split) %>%
    recipe(ph3 ~ t_a.p + g.p) %>%
    step_mutate(t_a.p.lp = lp_vector(t_a.p, a1 = coef_t)) %>%
    step_mutate(g.p.lp = lp_vector(g.p, a1 = coef_g)) %>%
    # step_corr(all_predictors()) %>%
    step_center(all_predictors(), -all_outcomes()) %>%
    step_scale(all_predictors(), -all_outcomes()) %>%
    prep()

  dm_train <- juice(rec)
  dm_test <- bake(rec, testing(split))

  return(list("train" = dm_train, "test" = dm_test, "rec" = rec))
}

# Get the model from `ti_train`
get_mod <- function(ti_train = li_dm$train) {
  mod_lm <- linear_reg() %>%
    set_engine("lm") %>%
    fit(ph3 ~ ., data = ti_train)
  return(mod_lm)
}

#' Evaluate the training and testing design matrix
get_rmse <- function(mod_lm, li_dm) {
  rmse <-
    li_dm$test %>%
    bind_cols(predict(mod_lm, .)) %>%
    metrics(truth = ph3, estimate = .pred) %>%
    `[[`(1, 3)

  return(rmse)
}

#' Evaluate the set of parameters for linear regression
val_para <- function(split, coef_t, coef_g, func_li_dm = get_li_dm_1) {
  li_dm <-
    split %>%
    func_li_dm(coef_t, coef_g)

  rmse <-
    li_dm %>%
    {get_mod(.$train)} %>%
    get_rmse(li_dm)

  return(rmse)
}

#' To cross validate the parameters
cv_para <- function(para, ti_cv, func_li_dm = get_li_dm_1) {
  rmse_mean <-
    ti_cv$splits %>%  # All the splits for cross validation
    # unlist(use.names = FALSE) %>%
    map_dbl(
      val_para, coef_t = para[1], coef_g = para[2], func_li_dm = func_li_dm
    ) %>%  # Apply the val_para to split one by one
    mean()

  rmse_mean %>%
    {glue("
      coef_t = {para[1]} ; coef_g = {para[2]} ; rmse_mean = {.} ;
      ")} %>%
    message()

  return(rmse_mean)
}

## ------------------------------------------------------------------------
## Split to training and testing sets
## Select the heating load from house 3
split_a1 <- li$pred %>%
  filter(ahead == 1) %>%
  left_join(li$time, by = "fo") %>%
  left_join(li$obs, by = "fo") %>%
  mutate(hour = as.numeric(hour(.$time))) %>%
  dplyr::select(fo, hour, t_a.p, g.p, ph3) %>%
  initial_split(0.6)

ti_cv <-
  split_a1 %>%
  training() %>%
  vfold_cv(v = 10, repeats = 1)

## Test the `get_li_dm_1` function
ti_cv %>%
  {.$splits[[1]]} %>%
  {get_li_dm_1(., 0.9, 0.9)} %>%
  print()

##
rec <-
  ti_cv %>%
  {.$splits[[1]]} %>%
  {get_li_dm_1(., 0.9, 0.9)} %>%
  {.$rec}

## Test the `cv_para` function
c(0.9, 0.9) %>%
  cv_para(ti_cv, get_li_dm_1)

## ------------------------------------------------------------------------
## Optimize the choice of low-pass filtering coefficients
result <-
  optim(
    c(t = 0.98, g = 0.98), cv_para,
    lower = c(0.3, 0.1), upper = c(0.999, 0.999), method = "L-BFGS-B",
    ti_cv = ti_cv, func_li_dm = get_li_dm_1
    ) %>%
  print()

## Result:
##   coef_t = 0.8688536
##   coef_g = 0.1000000
##   value = 0.9937975

## ------------------------------------------------------------------------
li_dm_1 <-
  split_a1 %>%
  get_li_dm_1(coef_t = result$par[[1]], coef_g = result$par[[2]])

mod_lm_1 <-
  li_dm_1 %>%
  {get_mod(.$train)}

li_dm_1$test %>%
  bind_cols(predict(mod_lm_1, .)) %>%
  metrics(truth = ph3, estimate = .pred) %>%
  `[[`(1, 3)

li_dm_1$test %>%
  bind_cols(predict(mod_lm_1, .), "index" = as.numeric(rownames(.))) %>%
  gather(ph3, .pred, key = "type", value = "heat_load") %>%
  dplyr::select(index, heat_load, type) %>%
  ggplot() +
  geom_line(aes(x = index, y = heat_load, color = type)) +
  labs(
    title = "Obs and Linear Reg Pred of Heat Load in House 3",
    subtitle = paste0(
      "with 1-step forecasted ambient temp and ",
      "1-step forecasted radiation as input"
    ),
    x = "index", y = "heat_load (W)"
  )

