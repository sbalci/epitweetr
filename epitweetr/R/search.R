
#' @title Runs the search loop
#' @description Infinite loop ensuring the permanent collection of tweets 
#' @param data_dir optional path to the 'data directory' containing application settings, models and collected tweets. If not provided it will reuse the last set on the current session.
#' If not provided the system will try to reuse the existing one from last session call of \code{\link{setup_config}} or use the EPI_HOME environment variable, Default: NA
#' @return Nothing
#' @details The detect loop is a pure R function designed for downloading tweets from the Twitter search API. It can handle several topics ensuring that all of them will be downloaded fairly using a 
#' round-robin philosophy and respecting Twitter API rate-limits.
#'
#' The progress of this task is reported on the 'topics.json' file which is read or created by this function. This function will try to collect tweets respecting a 'collect_span' window
#' in minutes, which is defined on the Shiny app and defaults to 60 minutes.
#'
#' To see more details about the collection algorithm please see epitweetr vignette.
#'
#' In order to work, this task needs Twitter credentials, which can be set on the Shiny app or using \code{\link{set_twitter_app_auth}}
#'
#' @examples 
#' if(FALSE){
#'    #Running the search loop
#'    library(epitweetr)
#'    message('Please choose the epitweetr data directory')
#'    search_loop(file.choose())
#' }
#' @rdname search_loop
#' @seealso
#' \code{\link{set_twitter_app_auth}}
#' @export 
search_loop <-  function(data_dir = NA) {
  # Setting or reusing the data directory
  if(is.na(data_dir) )
    setup_config_if_not_already()
  else
    setup_config(data_dir = data_dir)
  
  # Registering the search runner using current PID and ensuring no other instance of the search is actually running.
  register_search_runner()
  
  # Infinite loop for getting tweets if it is successfully registered as the search runner
  while(TRUE) {
    # On each iteration this loop will perform one request for each active plans having the minimum number of requests 
    # Creating plans for each topic if collect span is expired and calculating next execution time for each plan.
    for(i in 1:length(conf$topics)) {
      conf$topics[[i]]$plan <- update_plans(plans = conf$topics[[i]]$plan, schedule_span = conf$collect_span)
    }
     
    # Calculating how the time epitweetr should wait before executing each active plan. If bigger than zero then epitweetr will wait.
    # If waiting happens here, it means that epitweetr is able to collect all tweets under current twitter rate limits, so it could collect more topics or sooner.
    wait_for <- min(unlist(lapply(1:length(conf$topics), function(i) can_wait_for(plans = conf$topics[[i]]$plan))) )
    if(wait_for > 0) {
      message(paste(Sys.time(), ": All done! going to sleep for until", Sys.time() + wait_for, "during", wait_for, "seconds. Consider reducing the schedule_span for getting tweets sooner"))
      Sys.sleep(wait_for)
    }
    #getting only the next plan to execute for each topic (it could be a previous unfinished plan)
    next_plans <-lapply(1:length(conf$topics), function(i)  next_plan(plans = conf$topics[[i]]$plan))

    #calculating the minimum number of requests those plans have already executed
    min_requests <- Reduce(min, lapply(1:length(conf$topics), function(i) if(!is.null(next_plans[[i]])) next_plans[[i]]$request else .Machine$integer.max))

    #performing search only for plans with a minimum number of requests (round robin)
    for(i in 1:length(conf$topics)) { 
      for(j in 1:length(conf$topics[[i]]$plan)) { 
        plan <- conf$topics[[i]]$plan[[j]]
        if(plan$requests == min_requests && is.null(plan$end_on)) {
            conf$topics[[i]]$plan[[j]] = search_topic(plan = plan, query = conf$topics[[i]]$query, topic = conf$topics[[i]]$topic) 
        }
      }
    }
    #Updating config to take in consideration possible changed on topics or other settings (plans are saved before reloading config)
    setup_config(data_dir = conf$data_dir, save_first = list("topics"))
  }
}

# getting tweets for a particular plan, query and topic
# this function is called by the search_loop 
# plan: contains the id range that is being collected and the last tweet obtained. This will allow epitweetr to target the tweets to obtain on current request
# query: contains the text query to be sent to twitter
# topic: the topic to register the results on 
# returns the updated plan after search
search_topic <- function(plan, query, topic) {
  message(paste("searching for topic", topic, "from", plan$since_target, "until", if(is.null(plan$since_id)) "(last tweet)" else plan$since_id))
  # Tweets are stored on the following folder structure data_folder/tweets/search/topic/year
  # Ensuring that folders for storing tweets are created
  year <- format(Sys.time(), "%Y")
  create_dirs(topic, year) 
  
  # Tweets are stored as gzipped files with the following naming: "YYYY.MM.DD.counter.json.gz"
  # Counter starts with 00001 and it is increased after the last file grows over 100M
  # getting prefix and regular expression for tweet archive name
  file_prefix <- paste(format(Sys.time(), "%Y.%m.%d"))
  file_pattern <- paste(format(Sys.time(), "%Y\\.%m\\.%d"))
  dir <- paste(conf$data_dir, "tweets", "search", topic, year, sep = "/")
 
  # files will contain all files matching the naming pattern the last alphabetically is going to be measured to evaluate if a new file has to be started
  files <- sort(list.files(path = dir, pattern = file_prefix))

  # file_name will contain the name of the gz file to add
  file_name <- (
    if(length(files) == 0) paste(file_prefix, formatC(1, width = 5, format = "d", flag = "0"),"json.gz",  sep = ".") # default case for first file
    else {
      #If last file matching pattern is smaller than 100MB we keep adding to the same file else a new incremented file is created
      last <- files[[length(files)]]
      if(file.info(paste(dir, last, sep="/"))$size / (1024*1024) < 100)
        last
      else {
        #Try to get current index after date as integer and increasing it by one, if not possible a 00001 index will be added
        parts <- strsplit(gsub(".json.gz", "", last),split="\\.")[[1]]
        if(length(parts)<=3 || is.na(as.integer(parts[[length(parts)]]))) 
          paste(c(parts, formatC(1, width = 5, format = "d", flag = "0"), "json.gz"), collapse = ".")
        else  
          paste(c(parts[1:length(parts)-1], formatC(as.integer(parts[[length(parts)]])+1, width = 5, format = "d", flag = "0"), "json.gz"), collapse = ".")
      }
    } 
  )

  # putting all parts together to get current file name
  dest <- paste(conf$data_dir, "tweets", "search", topic, year, file_name, sep = "/")
  
  # ensuring that query is smaller than 400 character (tweetr API limit) 
  if(nchar(query)< 400) {
    # doing the tweet search and storing the response object to obtain details on resp
    resp <- twitter_search(q = query, max_id = plan$since_id, since_id = plan$since_target)
    # Getting the response content as a character vector on content
    content = httr::content(resp,as="text")
    # Interpreting the content as JSON and storing the results on json (nested list with dataframes)
    # interpreting is necesssary know the number of obtained tweets and the id of the oldest tweet found and to keep tweet collecting stats
    # Saving uninterpreted content as a gzip archive
    json <- jsonlite::fromJSON(content)
    gz <- gzfile(dest, "a")
    write(content, gz, append=TRUE)
    close(gz)

    # evaluating if rows are obtained if not rows are obtained it means that the plan is finished 
    # plan end can be because all tweets were already collected no more tweets are available because of twitter history limits
    got_rows <- is.data.frame(json$statuses) && nrow(json$statuses) > 0
    
    # new since_id is the oldest tweet obtained by the request. It is normally provided by the response metadata, but we calculate it because sometimes is missing
    new_since_id = 
      if(!is.data.frame(json$statuses)) {
        bit64::as.integer64(json$search_metadata$since_id_str)  
      } else {
        Reduce(function(x, y) if(x < y) x else y, lapply(json$statuses$id_str, function(x) bit64::as.integer64(x) -1 ))
      }
    if(got_rows) {
      # If rows were obtained we update the stat file that will stored the posted date period of each gz archive. 
      # This is used to improve aggregating performance, by targeting only the files containing tweets for a particular date
      update_file_stats(
        filename = gsub(".gz", "", file_name), 
        topic = topic,
        year = year,
        first_date = min(parse_date(json$statuses$created_at)), 
        last_date = max(parse_date(json$statuses$created_at)) 
      )
    }
    # updating the plan data (new since_id, progress, number of collected tweets, etc. 
    request_finished(plan, got_rows = got_rows, max_id = json$search_metadata$max_id_str, since_id = new_since_id) 
  } else {
    # Managing the case when the query is too long
    warning(paste("Query too long for API for topic", topic), immediate. = TRUE) 
    plan$requests = plan$requests
    plan 
  }
}

# Updating statistic files
# This function is called after each successful tweet request
# stat json files are stored on data_dir/year/xyz.gz where xyz is the name of a search gzip archive
# stat files contains an array per topic indicating the posted period on that the collected files with the same name
# these files are used to improve aggregating performance, by targeting only the files containing tweets for a particular date
# filename: gzip file to update stats on
# topic: topic to update the the stats on
# year: current year to separate the stat files per year
# first_date: oldest date on the tweets collected this will replace the stat if it is older than the current oldest date for the topic on the given file
# last_date: newest date on the tweets collected this will replace the stat if it is newer than the current newest date for the topic on the given file
update_file_stats <- function(filename, topic, year, first_date, last_date) {
   # getting the stat destination file
   stat_dir <- file.path(conf$data_dir, "stats")
   if(!file.exists(stat_dir)) dir.create(stat_dir)
   stat_dir <- file.path(stat_dir, year)
   if(!file.exists(stat_dir)) dir.create(stat_dir)
   dest <- file.path(stat_dir, filename)
   now <- Sys.time()
   #Setting UTC so it can be compares with twitter created dates
   attr(now, "tzone") <- "UTC"
   
   # reading current statustics if they exists
   stats <- 
     if(!file.exists(dest)) 
       list()
     else
       jsonlite::read_json(dest, simplifyVector = FALSE, auto_unbox = TRUE) 
    
    # matching record or creating new one
    found <- FALSE
    # updatinf stat file if it is foung
    if(length(stats)> 0) { 
      for(i in 1:length(stats)) {
        if(stats[[i]]$topic == topic) {
          found <- TRUE
          stats[[i]]$collected_to <- now
          if(stats[[i]]$created_from > first_date) stats[[i]]$created_from <- first_date
          if(stats[[i]]$created_to < last_date) stats[[i]]$created_to <- last_date
          break  
        }
      }
    }
    # creating new statistics if not found 
    if(!found) {
      stats[[length(stats)+1]] <- list(
        topic = topic,
        created_from =  first_date,
        created_to = last_date,
        collected_from = now,
        collected_to = now
      )
    }

    # saving modified json file
    write_json_atomic(stats, dest, pretty = TRUE, force = TRUE, auto_unbox = TRUE)
}

# Helper function to parse twiter date as provided by the twitter API
parse_date <- function(str_date) {
  curLocale <- Sys.getlocale("LC_TIME")
  on.exit(Sys.setlocale("LC_TIME", curLocale))
  Sys.setlocale("LC_TIME", "C")
  strptime(str_date, format = "%a %b %d %H:%M:%S +0000 %Y", tz="UTC")
}

# Perform a single page search on twitter API
# This function will build the twitter search URL for performing a search request on the standard search
# https://developer.twitter.com/en/docs/twitter-api/v1/tweets/search/api-reference/get-search-tweets
# function called from the search_topic function
# q: text query
# since_id: id of the oldest targeted tweet
# max_id: id of the newest targereted tweet
# result_type: sort criteria for tweets (recent, popular and mix) 
twitter_search <- function(q, since_id = NULL, max_id = NULL, result_type = "recent", count = 100) {
  search_url <- 
    paste(
      search_endopoint
      , "?q="
      , gsub("\\(", "%28", gsub("\\)", "%29", gsub("!", "%21", gsub("\\*", "%2A", gsub("'", "%27", xml2::url_escape(q)))))) #escaping url taking un consideration some unmanaged cases
      , if(!is.null(since_id)) "&since_id=" else ""
      , if(!is.null(since_id)) since_id else ""
      , if(!is.null(max_id)) "&max_id=" else  ""
      , if(!is.null(max_id)) max_id else  ""
      , "&result_type="
      , result_type
      , "&count="
      , count
      , "&include_entities=true"
      , sep = ""
    )
  res <- twitter_get(search_url)
  return(res)
}


# @title get_plan S3 class constructor
# @description Create a new 'get plan' for importing tweets using the Search API
# @param expected_end Character(\%Y-\%m-\%d \%H:\%M:\%S) establishing the target end datetime of this plan
# @param scheduled_for Character(\%Y-\%m-\%d \%H:\%M:\%S) establishing the expected datetime for next execution, default: Sys.time()
# @param start_on Character(\%Y-\%m-\%d \%H:\%M:\%S) establishing the datetime when this plan was first executed, default: NULL
# @param end_on Character(\%Y-\%m-\%d \%H:\%M:\%S) establishing the datetime when this plan has finished, default: NULL
# @param max_id Integer(64), the newest tweet collected by this plan represented by its tweet id. This value is defined after the first successful request is done and does not change by request, default: NULL
# @param since_id Integer(64) the oldest tweet that has currently been collected by this plan, this value is updated after each request, default: NULL
# @param since_target Interger(64), the oldest tweet id that is expected to be obtained by this plan, this value is set as the max_id from the previous plan + 1, default: NULL
# @param results_span Number of minutes after which this plan expires counting from start date, default: 0
# @param requests Integer, number of requests successfully executed, default: 0
# @param progress Numeric, percentage of progress of current plan defined when since_target_id is known or when a request returns no more results, default: 0
# @return The get_plan object defined by input parameters
# @details A plan is an S3 class representing a commitment to download tweets from the search API 
# It targets a specific time frame defined from the last tweet collected by the previous plan, if any, and the last tweet collected on its first request
# This commitment will be valid during a period of time defined from the time of its first execution until the end_on parameter
# a plan will perform several requests to the search API and each time a request is performed the number of requests will be increased.
# The field scheduled_for indicates the time when the next request is expected to be executed.
# @examples 
# if(FALSE){
#  #creating the default plan
#  get_plan()    
# }
# @seealso 
#  \code{\link[bit64]{as.integer64.character}}
# @rdname get_plan
# @importFrom bit64 as.integer64
get_plan <- function(
  expected_end
  , scheduled_for = Sys.time()
  , start_on = NULL
  , end_on = NULL
  , max_id = NULL
  , since_id = NULL
  , since_target = NULL
  , results_span = 0
  , requests = 0
  , progress = 0.0 
  ) {
  me <- list(
    "expected_end" = if(!is.null(unlist(expected_end))) strptime(unlist(expected_end), "%Y-%m-%d %H:%M:%S") else NULL
    , "scheduled_for" = if(!is.null(unlist(scheduled_for))) strptime(unlist(scheduled_for), "%Y-%m-%d %H:%M:%S") else NULL
    , "start_on" =if(!is.null(unlist(start_on))) strptime(unlist(start_on), "%Y-%m-%d %H:%M:%S") else NULL 
    , "end_on" = if(!is.null(unlist(end_on))) strptime(unlist(end_on), "%Y-%m-%d %H:%M:%S") else NULL
    , "max_id" = if(!is.null(unlist(max_id))) bit64::as.integer64(unlist(max_id)) else  NULL
    , "since_id" = if(!is.null(unlist(since_id))) bit64::as.integer64(unlist(since_id)) else NULL
    , "since_target" = if(!is.null(unlist(since_target))) bit64::as.integer64(unlist(since_target)) else NULL
    , "requests" = unlist(requests)
    , "progress" = unlist(progress)
  )
  class(me) <- append(class(me), "get_plan")
  return(me) 
}


# @title Update get plans 
# @description Updating plans for a particular topics
# @param plans The existing plans for the topic, default: list()
# @param schedule_target target minutes for finishing a plan 
# @return updated list of 'get_plan'
# @details
# This function will update the plan list of a topic taking in consideration the search span
# This function is called at the beggining of each search loop iteration applying the following rules
# If no plans are set, a new plan for getting all possible tweets will be set
# If current plan has started and the expected end has passed, a new plan will be added for collecting new tweets (previous plan will be stored for future execution if possible)
# Any finished plans after the first will be discharged (note that after 7 days all should be discharged because of empty results as a measure of precaution  a max od 100 plans are kept)
# @returns the updated list of plans
# @examples 
# if(FALSE){
#  #Getting deault plan
#  update_plans(plans = list(), schedule_span = 120) 
#  #Updating topics for first topic
#  update_plans(plans = conf$topics[[1]]$plan, schedule_span = conf$collect_span) 
# }
# @rdname update_plans
update_plans <- function(plans = list(), schedule_span) {
  # Testing if there are plans present
  if(length(plans) == 0) {
    # Getting default plan for when no existing plans are present setting the expected end
     return(list(get_plan(expected_end = Sys.time() + 60 * schedule_span)))
  } else if(plans[[1]]$requests > 0 && plans[[1]]$expected_end < Sys.time()) {
    # creating a new plan if expected end has passed 
    first <-  
      get_plan(
        expected_end = if(Sys.time()>plans[[1]]$expected_end + 60 * schedule_span) Sys.time() + 60 * schedule_span else plans[[1]]$expected_end + 60*schedule_span
        , since_target = plans[[1]]$max_id + 1
      )
    # removing ended plans
    non_ended <- plans[sapply(plans, function(x) is.null(x$end_on))]
    # removing plans if more of 100 plans are activeff
    return (append(list(first), if(length(non_ended)<100) non_ended else non_ended[1:100]))
  } else {
    first <- plans[[1]]
    rest <- plans[-1]
    # removing ended plans
    non_ended <- rest[unlist(sapply(rest, function(x) is.null(x$end_on)))]
    # removing ended plans
    return (append(list(first), if(length(non_ended)<100) non_ended else non_ended[1:100]))
  }
}

# Get next plan to plan to download
next_plan <- function(plans) {
  plans <- if("get_plan" %in% class(plans)) list(plans) else plans
  non_ended <- plans[sapply(plans, function(x) is.null(x$end_on))]
  if(length(non_ended) == 0) {
     return(NULL)
  } else {
    return(non_ended[[1]])
  }
}

# Calculating how long in seconds should epitweetr wait before executing one of the planson the list which would be the case only if all plans are finished before the end of the search span
can_wait_for <- function(plans) {
  plans <- if("get_plan" %in% class(plans)) list(plans) else plans
  non_ended <- plans[sapply(plans, function(x) is.null(x$end_on))]
  if(length(non_ended) == 0) {
     expected_end <- Reduce(min, lapply(plans, function(x) x$expected_end))
     return(ceiling(as.numeric(difftime(expected_end, Sys.time(), units = "secs"))))
  } else {
     return(0)
  }
}


# next plan generic function
request_finished <- function(current, got_rows, max_id, since_id = NULL) {
  UseMethod("request_finished",current)
}

# Update a plan after search request is done
# If first request, started and max will be set
# If results are non empty result span, since_id and max id are set
# If results are less than requested the search is suppossed to be finished
# If results are equals to the requested limit, more tweets are expected. In that case if the expected end has not yet arrived and we can estimate the remaining number of requests the next schedule will be set to an estimation of the necessary requests to finish. If we do not know, the current schedule will be left untouched.
request_finished.get_plan <- function(current, got_rows, max_id, since_id = NULL) {
  # increasing the number of requests
  current$requests <- current$requests + 1 
  
  # setting the start date after first request and max id that will be obtained by this plan
  if(is.null(current$start_on)) {
    current$start_on = Sys.time()
    current$max_id = bit64::as.integer64(max_id)
  }
  # setting the oldest id obtained by this plan (which should not go before since_target)
  if(!is.null(since_id)) {
    current$since_id <- bit64::as.integer64(since_id)
  }
  # calculating progress
  if(!is.null(current$since_target) && !is.null(current$since_id) && !is.null(current$max_id)) {
    current$progress <- as.double(current$max_id - current$since_id)/as.double(current$max_id - current$since_target)
  } 
  # Setting the end of the plan if no lines have been obtained
  if(!got_rows || (!is.null(current$since_target) && current$max_id == current$since_target)) {
    current$end_on <- Sys.time()
    #current$progress <- 1.0 
  } else {
    if(Sys.time() < current$expected_end && current$progress > 0.0) {
      # this property was designed to delay plans that cab quickly finish, but it has finally not being used. 
      progressByRequest <- current$progress / current$requests
      requestsToFinish <- (1.0 - current$progress)/progressByRequest
      current$scheduled_for = Sys.time() + as.integer(difftime(current$expected_end, Sys.time(), units = "secs"))/requestsToFinish 
    }
  }
  return(current)
}

# create topic directories if they do not exist
create_dirs <- function(topic = NA, year = NA) {
  if(!file.exists(paste(conf$data_dir, sep = "/"))){
    dir.create(paste(conf$data_dir, sep = "/"), showWarnings = FALSE)
  }  
  if(!file.exists(paste(conf$data_dir, "tweets", sep = "/"))){
    dir.create(paste(conf$data_dir, "tweets", sep = "/"), showWarnings = FALSE)
  }
  if(!file.exists(paste(conf$data_dir, "tweets", "search", sep = "/"))){
    dir.create(paste(conf$data_dir, "tweets", "search", sep = "/"), showWarnings = FALSE)
  }
  if(!is.na(topic) && !is.na(year)) {
    if(!file.exists(paste(conf$data_dir, "tweets", "search", topic, sep = "/"))){
      dir.create(paste(conf$data_dir, "tweets", "search", topic,  sep = "/"), showWarnings = FALSE)
    }  
    if(!file.exists(paste(conf$data_dir, "tweets", "search", topic, year , sep = "/"))){
      dir.create(paste(conf$data_dir, "tweets", "search", topic, year, sep = "/"), showWarnings = FALSE)
    } 
  }
}

# Get time difference since last request
# This function is used from the shiny app to report when was the last tile that a request saved tweets
# This is done by taking the last modified date of current year tweet files
last_search_time <- function() {
  topics <- list.files(path=paste(conf$data_dir, "tweets", "search", sep="/"))
  current_year <- lapply(topics, function(t) list.files(path=paste(conf$data_dir, "tweets", "search", t, sep="/"), pattern = strftime(Sys.time(), format = "%y$"), full.names=TRUE))
  current_year <- current_year[lapply(current_year,length)>0]
  if(length(current_year)>0) {
    last_child <- sapply(current_year, function(y) {
        children <- list.files(path = y, pattern = "*.gz", full.names=TRUE)
        if(length(children)>0)
          sort(children, decreasing=TRUE)[[1]]
        else 
          NA
      })
    last_child <- last_child[!is.na(last_child)]
    if(length(last_child)>0)
      sort(file.mtime(last_child), decreasing=TRUE)[[1]]
    else
      NA
  } else NA
}
