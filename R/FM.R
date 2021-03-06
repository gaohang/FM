#' @useDynLib FM
#' @importFrom Rcpp evalCpp
NULL

#' @name FM
#' @title Creates FactorizationMachines model.
#' @description Creates second order Factorization Machines model
#' @section Usage:
#' For usage details see \bold{Methods, Arguments and Examples} sections.
#' \preformatted{
#' fm = FM$new(learning_rate = 0.2, rank = 8, lambda_w = 1e-6, lambda_v = 1e-6, task = "classification")
#' fm$partial_fit(X, y, nthread  = 0, ...)
#' fm$predict(X, nthread  = 0, ...)
#' }
#' @format \code{\link{R6Class}} object.
#' @section Methods:
#' \describe{
#'   \item{\code{FM$new(learning_rate = 0.2, rank = 8, lambda_w = 1e-6, lambda_v = 1e-6, task = "classification")}}{Constructor
#'   for FactorizationMachines model. For description of arguments see \bold{Arguments} section.}
#'   \item{\code{$partial_fit(X, y, nthread  = 0, ...)}}{fits/updates model given input matrix \code{X} and target vector \code{y}.
#'   \code{X} shape = (n_samples, n_features)}
#'   \item{\code{$predict(X, nthread  = 0, ...)}}{predicts output \code{X}}
#'   \item{\code{$coef()}}{ return coefficients of the regression model}
#'   \item{\code{$dump()}}{create dump of the model (actually \code{list}) with current model parameters}
#'}
#' @section Arguments:
#' \describe{
#'  \item{fm}{\code{FTRL} object}
#'  \item{X}{Input sparse matrix - native format is \code{Matrix::RsparseMatrix}.
#'  If \code{X} is in different format, model will try to convert it to \code{RsparseMatrix}
#'  with \code{as(X, "RsparseMatrix")} call}
#'  \item{learning_rate}{learning rate for AdaGrad SGD}
#'  \item{rank}{rank of the latent dimension in factorization}
#'  \item{lambda_w}{regularization parameter for linear terms}
#'  \item{lambda_v}{regularization parameter for interactions terms}
#'  \item{n_features}{number of features in model (number of columns in expected model matrix) }
#'  \item{task}{ \code{"regression"} or \code{"classification"}}
#' }
#' @export
FM = R6::R6Class(
  classname = "estimator",
  public = list(
    #-----------------------------------------------------------------
    initialize = function(learning_rate = 0.2, rank = 4,
                          lambda_w = 0, lambda_v = 0,
                          task = c("classification", "regression"),
                          intercept = TRUE) {
      stopifnot(lambda_w >= 0 && lambda_v >= 0 && learning_rate > 0 && rank >= 1)
      task = match.arg(task);
      private$learning_rate = learning_rate
      private$rank = rank
      private$lambda_w = lambda_w
      private$lambda_v = lambda_v
      private$task = task
      private$intercept = intercept
    },
    partial_fit = function(X, y, nthread = 0, weights = rep(1.0, length(y)), ...) {
      if(!inherits(class(X), private$internal_matrix_format)) {
        X = as(X, private$internal_matrix_format)
      }
      X_ncol = ncol(X)
      # init model during first first fit
      if(!private$is_initialized) {
        private$n_features = X_ncol
        #---------------------------------------------
        private$w0 = 0L
        fill_float_vector(private$w0, 0.0)
        #---------------------------------------------
        private$w = integer(private$n_features)
        fill_float_vector_randn(private$w, 0.001)
        #---------------------------------------------
        private$v = matrix(0L, nrow = private$rank, ncol = private$n_features)
        fill_float_matrix_randn(private$v, 0.001)
        #---------------------------------------------
        private$grad_w2 = integer(private$n_features)
        fill_float_vector(private$grad_w2, 1.0)
        #---------------------------------------------
        private$grad_v2 = matrix(0L, nrow = private$rank, ncol = private$n_features)
        fill_float_matrix(private$grad_v2, 1.0)
        #---------------------------------------------
        private$ptr_param = fm_create_param(private$learning_rate, private$rank, private$lambda_w, private$lambda_v,
                                            private$w0,
                                            private$w, private$v,
                                            private$grad_w2, private$grad_v2,
                                            private$task,
                                            private$intercept)
        private$ptr_model = fm_create_model(private$ptr_param)
        private$is_initialized = TRUE
      }
      # on consequent updates check that we are wotking with input matrix with same numner of features
      stopifnot(X_ncol == private$n_features)
      # check number of samples = number of outcomes
      stopifnot(nrow(X) == length(y))
      stopifnot(is.numeric(weights) && length(weights) == length(y))
      stopifnot(!anyNA(y))
      # convert to (1, -1) as it required by loss function in FM
      if(private$task == 'classification')
        y = ifelse(y == 1, 1, -1)

      # check no NA - anyNA() is by far fastest solution
      if(anyNA(X@x))
        stop("NA's in input matrix are not allowed")

      p = fm_partial_fit(private$ptr_model, X, y, weights, do_update = TRUE, nthread = nthread)
      invisible(p)
    },
    predict =  function(X, nthread = 0, ...) {
      if(is.null(private$ptr_param) || is_invalid_ptr(private$ptr_param)) {
        print("is.null(private$ptr_param) || is_invalid_ptr(private$ptr_param)")
        if(private$is_initialized) {
          print("init private$ptr_param")
          private$ptr_param = fm_create_param(private$learning_rate, private$rank, private$lambda_w, private$lambda_v,
                                              private$w0,
                                              private$w, private$v,
                                              private$grad_w2, private$grad_v2,
                                              private$task,
                                              private$intercept)
          private$ptr_model = fm_create_model(private$ptr_param)
        }
      }
      stopifnot(private$is_initialized)
      if(!inherits(class(X), private$internal_matrix_format)) {
        X = as(X, private$internal_matrix_format)
      }
      stopifnot(ncol(X) == private$model$n_features)

      if(any(is.na(X)))
        stop("NA's in input matrix are not allowed")
      # dummy numeric(0) - don't have y and don't need weights
      p = fm_partial_fit(private$ptr_model, X, numeric(0), numeric(0), do_update = FALSE, nthread = nthread)
      return(p);
    }
  ),
  private = list(
    #--------------------------------------------------------------
    is_initialized = FALSE,
    internal_matrix_format = "RsparseMatrix",
    #--------------------------------------------------------------
    ptr_param = NULL,
    ptr_model = NULL,
    #--------------------------------------------------------------
    n_features = NULL,
    learning_rate = NULL,
    rank = NULL,
    lambda_w = NULL,
    lambda_v = NULL,
    task = NULL,
    intercept = NULL,
    #--------------------------------------------------------------
    # these 5 will be modified in place in C++ code
    #--------------------------------------------------------------
    v = NULL,
    w = NULL,
    w0 = NULL,
    grad_v2 = NULL,
    grad_w2 = NULL
  )
)

