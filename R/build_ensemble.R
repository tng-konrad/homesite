## wd etc ####
require(readr)
require(stringr)
require(glmnet)
require(caret)
require(xgboost)
require(nnet)
require(ranger)

seed_value <- 9770
todate <- str_replace_all(Sys.Date(), "-","")
nbag <- 2

## functions ####

msg <- function(mmm,...)
{
  cat(sprintf(paste0("[%s] ",mmm),Sys.time(),...)); cat("\n")
}


auc<-function (actual, predicted) {
  
  r <- as.numeric(rank(predicted))
  
  n_pos <- as.numeric(sum(actual == 1))
  n_neg <- as.numeric(length(actual) - n_pos)
  auc <- (sum(r[actual == 1]) - n_pos * (n_pos + 1)/2)/(n_pos *  n_neg)
  auc
  
}

# build an ensemble, input = parameters(initSize,howMany,blendIt, blendProp),
# input x, input y (x0 / y0 in c-v)
# output = list(weight)
buildEnsemble <- function(parVec, xset, yvec)
{
  set.seed(20130912)
  # ensemble settings
  initSize <- parVec[1]; howMany <- parVec[2];
  blendIt <- parVec[3]; blendProp <- parVec[4]
  
  # storage matrix for blending coefficients
  arMat <- array(0, c(blendIt, ncol(xset)))
  colnames(arMat) <- colnames(xset)
  
  # loop over blending iterations
  dataPart <- createDataPartition(1:ncol(arMat), times = blendIt, p  = blendProp)
  for (bb in 1:blendIt)
  {
    idx <- dataPart[[bb]];    xx <- xset[,idx]
    
    # track individual scores
    trackScore <- apply(xx, 2, function(x) auc(yvec,x))
    
    # select the individual best performer - store the performance
    # and create the first column -> this way we have a non-empty ensemble
    bestOne <- which.max(trackScore)
    mastaz <- (rank(-trackScore) <= initSize)
    best.track <- trackScore[mastaz];    hillNames <- names(best.track)
    hill.df <- xx[,mastaz, drop = FALSE]
    
    # loop over adding consecutive predictors to the ensemble
    for(ee in 1 : howMany)
    {
      # add a second component
      trackScoreHill <- apply(xx, 2,
                              function(x) auc(yvec,rowMeans(cbind(x , hill.df))))
      
      best <- which.max(trackScoreHill)
      best.track <- c(best.track, max(trackScoreHill))
      hillNames <- c(hillNames,names(best))
      hill.df <- data.frame(hill.df, xx[,best])
      msg(ee)
    }
    
    ww <- summary(factor(hillNames))
    arMat[bb, names(ww)] <- ww
    msg(paste("blend: ",bb, sep = ""))
  }
  
  wgt <- colSums(arMat)/sum(arMat)
  
  return(wgt)
}

## data ####
# list the groups 
xlist_val <- dir("./metafeatures/", pattern =  "prval", full.names = T)
xlist_full <- dir("./metafeatures/", pattern = "prfull", full.names = T)

# aggregate validation set
ii <- 1
mod_class <- str_split(xlist_val[[ii]], "_")[[1]][[2]]
xvalid <- read_csv(xlist_val[[ii]])
xcols <- colnames(xvalid)[1:(ncol(xvalid)-2)]
xcols <- paste(xcols , ii, sep = "")
colnames(xvalid)[1:(ncol(xvalid)-2)] <- xcols

for (ii in 2:length(xlist_val))
{
  mod_class <- str_split(xlist_val[[ii]], "_")[[1]][[2]]
  xval <- read_csv(xlist_val[[ii]])
  xcols <- colnames(xval)[1:(ncol(xval)-2)]
  xcols <- paste(xcols , ii, sep = "")
  colnames(xval)[1:(ncol(xval)-2)] <- xcols
  xvalid <- merge(xvalid, xval)
  msg(ii)
}

# aggregate test set
ii <- 1
mod_class <- str_split(xlist_full[[ii]], "_")[[1]][[2]]
xfull <- read_csv(xlist_full[[ii]])
xcols <- colnames(xfull)[1:(ncol(xfull)-1)]
xcols <- paste(xcols , ii, sep = "")
colnames(xfull)[1:(ncol(xfull)-1)] <- xcols

for (ii in 2:length(xlist_val))
{
  xval <- read_csv(xlist_full[[ii]])
  xcols <- colnames(xval)[1:(ncol(xval)-1)]
  xcols <- paste(xcols , ii, sep = "")
  colnames(xval)[1:(ncol(xval)-1)] <- xcols
  xfull <- merge(xfull, xval)
  msg(ii)
}

rm(xval)


## build ensemble model ####

# prepare the data
y <- xvalid$QuoteConversion_Flag; xvalid$QuoteConversion_Flag <- NULL
id_valid <- xvalid$QuoteNumber; xvalid$QuoteNumber <- NULL
id_full <- xfull$QuoteNumber; xfull$QuoteNumber <- NULL

# produce a plot of possible metafeatures values
meta_values <- apply(xvalid,2,function(s) auc(y,s))
# plot(density(meta_values), xlab = "cross-validated AUC score", ylab  = "", main = "Lvl1 metafeatures scores distribution")
xgb_indices <- grep("xgb", names(meta_values))
plot(density(meta_values[xgb_indices]), xlab = "cross-validated AUC score: xgb models", ylab  = "", main = "Score distribution for level 1 metafeatures")


# folds for cv evaluation
xfolds <- read_csv("./input/xfolds.csv"); xfolds$fold_index <- xfolds$fold5
xfolds <- xfolds[,c("QuoteNumber", "fold_index")]
nfolds <- length(unique(xfolds$fold_index))

# storage for results
storage_matrix <- array(0, c(nfolds, 5))

# storage for level 2 forecasts 
xvalid2 <- array(0, c(nrow(xvalid),5))
xfull2 <- array(0, c(nrow(xfull),5))

# trim linearly dependent ones 
print(paste("Pre linear combo trim size ", dim(xvalid)[2]))
flc <- findLinearCombos(xvalid)
if (length(flc$remove))
{
  xvalid <- xvalid[,-flc$remove]
  xfull <- xfull[,-flc$remove]
}
print(paste(" Number of cols after linear combo extraction:", dim(xvalid)[2]))

# amend the data
xMed <- apply(xvalid,1,median); xMin <- apply(xvalid,1,min)
xMax <- apply(xvalid,1,max); xMad <- apply(xvalid,1,mad)
xq1 <- apply(xvalid,1, function(s) quantile(s, 0.1))
xq2 <- apply(xvalid,1, function(s) quantile(s, 0.25))
xq3 <- apply(xvalid,1, function(s) quantile(s, 0.75))
xq4 <- apply(xvalid,1, function(s) quantile(s, 0.9))
xvalid$xmed <- xMed; xvalid$xmax <- xMax; xvalid$xmin <- xMin; xvalid$xmad <- xMad
xvalid$xq1 <- xq1; xvalid$xq2 <- xq2; xvalid$xq3 <- xq3; xvalid$xq4 <- xq4

xq1 <- apply(xfull,1, function(s) quantile(s, 0.1))
xq2 <- apply(xfull,1, function(s) quantile(s, 0.25))
xq3 <- apply(xfull,1, function(s) quantile(s, 0.75))
xq4 <- apply(xfull,1, function(s) quantile(s, 0.9))
xMed <- apply(xfull,1,median); xMin <- apply(xfull,1,min)
xMax <- apply(xfull,1,max); xMad <- apply(xfull,1,mad)
xfull$xmed <- xMed; xfull$xmax <- xMax; xfull$xmin <- xMin; xfull$xmad <- xMad
xfull$xq1 <- xq1; xfull$xq2 <- xq2; xfull$xq3 <- xq3; xfull$xq4 <- xq4

rm(xq1, xq2, xq3, xq4, xMad, xMax, xMed, xMin)


# To save dataset for quick optimizations
xvalid$QuoteConversion_Flag <- y 
xvalid$QuoteNumber <- id_valid
write.csv(xvalid, paste('./input/xvalid_', todate, '.csv', sep = ""), row.names = F)
xvalid$QuoteConversion_Flag <- NULL
xvalid$QuoteNumber <- NULL

xfull$QuoteNumber <- id_full
write.csv(xfull, paste('./input/xfull_', todate, '.csv', sep = ""), row.names = F)
xfull$QuoteNumber <- NULL

for (ii in 1:nfolds)
{
  # mix with glmnet: average over multiple alpha parameters 
  isTrain <- which(xfolds$fold_index != ii)
  isValid <- which(xfolds$fold_index == ii)
  x0 <- xvalid[isTrain,];   x1 <- xvalid[isValid,]
  y0 <- y[isTrain];  y1 <- y[isValid]
  prx1 <- y1 * 0
  for (jj in 1:11)
  {
    mod0 <- glmnet(x = as.matrix(x0), y = y0, alpha = (jj-1) * 0.1)
    prx <- predict(mod0,as.matrix(x1))  
    prx <- prx[,ncol(prx)]
    prx1 <- prx1 + prx
  }
  storage_matrix[ii,1] <- auc(y1,prx1)
  xvalid2[isValid,1] <- prx1
  
  # mix with xgboost: bag over multiple seeds
  x0d <- xgb.DMatrix(as.matrix(x0), label = y0)
  x1d <- xgb.DMatrix(as.matrix(x1), label = y1)
  watch <- list(valid = x1d)
  prx2 <- y1 * 0
  for (jj in 1:nbag)
  {
    set.seed(seed_value + 1000*jj + 2^jj + 3 * jj^2)
    clf <- xgb.train(booster = "gbtree", 
                     maximize = TRUE, 
                     print.every.n = 50, 
                     nrounds = 621,
                     eta = 0.021700388765921064, 
                     max.depth = 9,
                     colsample_bytree = 0.83914630981480487, 
                     subsample = 0.87375172168899873,
                     min_child_weight = 19.343366117536888,
                     data = x0d, 
                     objective = "binary:logistic",
                     watchlist = watch, 
                     eval_metric = "auc", 
                     gamma= 0.00012527443501287444)
    prx <- predict(clf, x1d)
    prx2 <- prx2 + prx
  }
  prx2 <- prx2 / nbag
  storage_matrix[ii,2] <- auc(y1,prx2)
  xvalid2[isValid,2] <- prx2
  
  # mix with nnet:  
  prx3 <- y1 * 0
  for (jj in 1:nbag)
  {
    set.seed(seed_value + 1000*jj + 2^jj + 3 * jj^2)
    net0 <- nnet(factor(y0) ~ ., data = x0, size = 40, MaxNWts = 20000, decay = 0.02)
    prx3 <- prx3 + predict(net0, x1)
  }
  prx3 <- prx3 /nbag
  storage_matrix[ii,3] <- auc(y1,prx3)
  xvalid2[isValid,3] <- prx3

  # mix with hillclimbing
  par0 <- buildEnsemble(c(1,15,5,0.6), x0,y0)
  prx4 <- as.matrix(x1) %*% as.matrix(par0)
  storage_matrix[ii,4] <- auc(y1,prx4)
  xvalid2[isValid,4] <- prx4
  
  # mix with random forest
  rf0 <- ranger(factor(y0) ~ ., data = x0, 
         mtry = 25, num.trees = 350,
         write.forest = T, probability = T,
         min.node.size = 10, seed = seed_value,
         num.threads = 4)
  prx5 <- predict(rf0, x1)$predictions[,2]
  storage_matrix[ii,5] <- auc(y1,prx5)
  xvalid2[isValid,5] <- prx5
  
  msg(paste("fold ",ii,": finished", sep = ""))
}

## build prediction on full set
# glmnet
prx1 <- rep( 0, nrow(xfull))
for (jj in 1:11)
{
  mod0 <- glmnet(x = as.matrix(xvalid), y = y, alpha = (jj-1) * 0.1)
  prx <- predict(mod0,as.matrix(xfull))  
  prx <- prx[,ncol(prx)]
  # storage_matrix[ii,jj] <- auc(y1,prx1)
  prx1 <- prx1 + prx
}
prx1 <- rank(prx1)/length(prx1)
xfull2[,1] <- prx1

# xgboost
x0d <- xgb.DMatrix(as.matrix(xvalid), label = y)
x1d <- xgb.DMatrix(as.matrix(xfull))
prx2 <- rep(0, nrow(xfull))
for (jj in 1:nbag)
{
  set.seed(seed_value + 1000*jj + 2^jj + 3 * jj^2)
  clf <- xgb.train(booster = "gbtree", 
                   maximize = TRUE, 
                   print.every.n = 50, 
                   nrounds = 621,
                   eta = 0.021700388765921064, 
                   max.depth = 9,
                   colsample_bytree = 0.83914630981480487, 
                   subsample = 0.87375172168899873,
                   min_child_weight = 19.343366117536888,
                   data = x0d, 
                   objective = "binary:logistic",
                   # watchlist = watch, 
                   eval_metric = "auc", 
                   gamma= 0.00012527443501287444)
  prx <- predict(clf, x1d)
  prx2 <- prx2 + prx
}
prx2 <- prx2 / nbag
xfull2[,2] <- prx2

# mix with nnet 
prx3 <- rep(0, nrow(xfull))
for (jj in 1:nbag)
{
  set.seed(seed_value + 1000*jj + 2^jj + 3 * jj^2)
  net0 <- nnet(factor(y) ~ ., data = xvalid, size = 40, MaxNWts = 20000, decay = 0.02)
  prx3 <- prx3 + predict(net0, xfull)
}
prx3 <- prx3 /nbag
xfull2[,3] <- prx3

# mix with hillclimbing
par0 <- buildEnsemble(c(1,15,5,0.6), xvalid,y)
prx4 <- as.matrix(xfull) %*% as.matrix(par0)
xfull2[,4] <- prx4

# mix with ranger
rf0 <- ranger(factor(y) ~ ., data = xvalid, 
              mtry = 25, num.trees = 350,
              write.forest = T, probability = T,
              min.node.size = 10, seed = seed_value,
              num.threads = 4)
prx5 <- predict(rf0, xfull)$predictions[,2]
xfull2[,5] <- prx5

rm(y0,y1, x0d, x1d, rf0, prx1,prx2,prx3,prx4,prx5)
rm(par0, net0, mod0,mod_class, clf,x0, x1)

# dump the 2nd level forecasts
xvalid2 <- data.frame(xvalid2)
xvalid2$QuoteConversion_Flag <- y 
xvalid2$QuoteNumber <- id_valid
write.csv(xvalid2, paste("./input/xvalid_lvl2_",todate,"_bag",nbag,".csv", sep = ""), row.names = F)
xvalid2$QuoteConversion_Flag <- NULL
xvalid2$QuoteNumber <- NULL

xfull2 <- data.frame(xfull2)
xfull2$QuoteNumber <- id_full
write.csv(xfull2, paste("./input/xfull_lvl2_",todate,"_bag",nbag,".csv", sep = ""), row.names = F)
xfull2$QuoteNumber <- NULL

# produce a table summarizing level 2 behaviour
xval <- read_csv("./input/xvalid_lvl2_20160129_bag5.csv")
xtab <- array(0, c(nfolds, 5))
for (ii in 1:nfolds)
{
  # mix with glmnet: average over multiple alpha parameters 
  isTrain <- which(xfolds$fold_index != ii)
  isValid <- which(xfolds$fold_index == ii)
  x0 <- xval[isTrain,1:5];   x1 <- xval[isValid,1:5]
  y0 <- xval$QuoteConversion_Flag[isTrain];  y1 <- xval$QuoteConversion_Flag[isValid]
  xtab[ii,] <-  apply(x1[,1:5],2,function(s) auc(y1,s))
}
colnames(xtab) <- c("glmnet", "xgb", "nnet", "hillclimb", "ranger")
write_csv(data.frame(round(xtab,6)), path = "ensemble_lvl2_results.csv")

## final ensemble forecasts ####
# evaluate performance across folds
storage2 <- array(0, c(nfolds,3))
param_mat <- array(0, c(nfolds, 5))
for (ii in 1:nfolds)
{
  isTrain <- which(xfolds$fold_index != ii)
  isValid <- which(xfolds$fold_index == ii)
  x0 <- apply(xvalid2[isTrain,],2,rank)/length(isTrain)
  x1 <- apply(xvalid2[isValid,],2,rank)/length(isValid)
  x0 <- data.frame(x0); x1 <- data.frame(x1)
  y0 <- y[isTrain];  y1 <- y[isValid]
  
  par0 <- buildEnsemble(c(1,15, 5,0.6), x0,y0)
  pr1 <- as.matrix(x1) %*% as.matrix(par0)
  storage2[ii,1] <- auc(y1, pr1)
  param_mat[ii,] <- par0
  
}

# find the best combination of mixers
xvalid2 <- apply(xvalid2,2,rank)/nrow(xvalid2)
xfull2 <- apply(xfull2,2,rank)/nrow(xfull2)
xvalid2 <- data.frame(xvalid2)
xfull2 <- data.frame(xfull2)

# construct forecast
par0 <- buildEnsemble(c(1,15, 5,0.6), xvalid2,y)
prx <- as.matrix(xfull2) %*% as.matrix(par0)
xfor <- data.frame(QuoteNumber = id_full, QuoteConversion_Flag = prx)

print(paste("mean: ", mean(storage2[,1])))
print(paste("sd: ", sd(storage2[,1])))

# store
todate <- str_replace_all(Sys.Date(), "-","")
write_csv(xfor, path = paste("./submissions/ens_bag",nbag,"_",todate,"_seed",seed_value,".csv", sep = ""))