library(shiny)
library(tercen)
library(dplyr)
library(tidyr)
library(tiff)
library(ijtiff)
library(gridExtra)
library(png)
library(grid)



############################################
#### This part should not be modified
getCtx <- function(session) {
  # retreive url query parameters provided by tercen
  query <- parseQueryString(session$clientData$url_search)
  token <- query[["token"]]
  taskId <- query[["taskId"]]
  
  # create a Tercen context object using the token
  ctx <- tercenCtx(taskId = taskId, authToken = token)
  return(ctx)
}
####
############################################

get_barcode <- function(img){
  
    tmp <- stringr::str_split( img, "/" )[[1]]
    tmp <- tmp[[length(tmp)]]
    tmp <- stringr::str_split( tmp, "_" )[[1]][1]
    return(tmp)
}

get_well <- function(img){
    tmp <- stringr::str_split( img, "/" )[[1]]
    tmp <- tmp[[length(tmp)]]
    tmp <- stringr::str_split( tmp, "_" )[[1]][2]
    #tmp <- substr(tmp,2,2)
    
    return(tmp)
}


server <- shinyServer(function(input, output, session) {
  
  values <- reactiveValues()
  
  dataInput <- reactive({
    values$df <- getData(session)
    values$df
  })
  
  output$reacOut <- renderUI({
    tagList(
      HTML("<h3><center>Image overview</center></h3>"),
      fluidRow(
        column(2),
        column(2, selectizeInput("cycleId", "Cycle", choices = c(LOADING_DATA))),
        column(2, selectizeInput("exposureTimeId", "Filter_Exposure Time", choices = c(LOADING_DATA))),
        column(2)
      ),
      tags$p(),
      fluidRow(
        column(1),
        column(10, plotOutput("plot")))
    )
  })
  
  get_plot_width <- reactive({
    df    <- dataInput()
    ncols <- length(unique(df$Barcode))
    ncols * 270
  })
  
  get_plot_height <- reactive({
    df    <- dataInput()
    
    nrows <- length(unique(df$Row))
    nrows * 200
  })
  
  output$plot <- renderPlot({
    df <- dataInput()
    
    # filtering
    if (input$exposureTimeId != LOADING_DATA && input$cycleId != LOADING_DATA) {
      df <- df %>%
        filter(`Exposure Time` == input$exposureTimeId) %>%
        filter(Cycle == input$cycleId)
      
      # convert to png and display in grid
      if (nrow(df) > 0) {
        tiff_images <- df$Image
        png_img_dir <- paste0( tempdir(), "/png")
        if (dir.exists(png_img_dir)) {
          system(paste("rm -rf", png_img_dir))
        }
        
        dir.create(png_img_dir)
        
        #Order images by Well (W1, W1, W1, W2, W2, W2) then I
        orderStr <- unlist(lapply(tiff_images, function(x){
          paste0(
            strsplit(basename(x), "_")[[1]][2], 
            "_",
            strsplit(basename(x), "_")[[1]][6])
        }))
        
        imgIdx <- sort(orderStr, index.return=T)
        
        factor <- 1
        targetMedian <- 0.25
        offsets <- seq(-0.3, 3, 0.1)
        med <- c()
        tiffImg <- suppressWarnings(tiff::readTIFF(tiff_images[imgIdx$ix[1]]) * 16)
        for( k in seq(1, length(offsets))){
          factorOff <- offsets[k]
          tmp <- tiffImg * (factor + factorOff)
          tmp[tmp>1] <- 1
          
          med <-  append(med, median(tmp * (factor + factorOff)) )
        }
        d <- abs(targetMedian - med)
        facAdj <- offsets[which( d == min(d))]
        
        #TODO Map file names to specific row and column (gaps might exist)
        nrows     <- length(unique(df$Row))
        c_titles  <- unique(df$Barcode)
        r_titles  <- as.character(seq(nrows))
        
        barcodes <- unlist(lapply(tiff_images, function(img){
          get_barcode(img)}))
        rows <- unlist(lapply(tiff_images, function(img){
          get_well(img)}))
        
        # Create a default, blank image for datasets with missing barcode or row
        tiff_file <- tiff_images[1]
        tiffImg <- suppressWarnings(tiff::readTIFF(tiff_file) * 16) * (factor + facAdj)
        blankTiffImg <- tiffImg * 0 + 1
        
        plotIdx <- 1
        
        # Grid is filled barcode (column) first
        for( r in seq(1, length(r_titles))){
          row = paste0("W", r_titles[r])
          for( c in seq(1, length(c_titles))){
            barcode = c_titles[c]

            idx <- which(unlist(lapply(tiff_images, function(img){
              imgBc <- get_barcode(img)
              imgW <- get_well(img)
              
              grepl(imgBc, barcode) && grepl(imgW, row)
            })))
            
            png_file  <- file.path(png_img_dir, paste0("out", formatC(plotIdx, width=3, flag="0") , ".png"))
            
            if(length(idx) == 0){
              png::writePNG(blankTiffImg, png_file)
            }else{
              tiff_file <- tiff_images[idx]  
              tiffImg <- suppressWarnings(tiff::readTIFF(tiff_file) * 16) * (factor + facAdj)
              tiffImg[tiffImg>1] <- 1
              png::writePNG(tiffImg, png_file)
            }
            session$onSessionEnded(function(){ unlink(png_file)  })
            
            plotIdx <- plotIdx + 1
          }
        }

        png_files <- list.files(path = png_img_dir, pattern = "*.png", full.names = TRUE)
        png_files <- normalizePath(png_files)
        png_files <- png_files[file.exists(png_files)]
        pngs      <- lapply(png_files, readPNG)
        asGrobs   <- lapply(pngs, FUN = function(png) { rasterGrob(png, height = 0.99)  })
        
        theme     <- ttheme_minimal(base_size = 16 )

        combinedPlot <- rbind(tableGrob(t(c_titles), theme = theme, rows = ""), 
                              cbind(tableGrob(r_titles, theme = theme),
                                    arrangeGrob(grobs = asGrobs, nrow = nrows), size = "last"), size = "last")
        
        grid.newpage()
        grid.draw(combinedPlot)
      }
    }
  }, height = get_plot_height, width = get_plot_width)
  
  observeEvent(values$df, {
    df <- values$df

    if( input$cycleId == LOADING_DATA && input$exposureTimeId == LOADING_DATA){
      sorted_cycles <- sort(unique(df$Cycle))
      sorted_exp_time <- sort(unique(df$`Exposure Time`))
      updateSelectizeInput(session, "cycleId", choices = sorted_cycles,
                           selected = sorted_cycles[length(sorted_cycles)])
      updateSelectizeInput(session, "exposureTimeId", choices = sorted_exp_time,
                           selected = sorted_exp_time[length(sorted_exp_time)])
    }else{
      updateSelectizeInput(session, "cycleId", choices = sort(unique(df$Cycle)))
      updateSelectizeInput(session, "exposureTimeId", choices = sort(unique(df$`Exposure Time`)))  
    }
    
  })
})

TAG_LIST  <- list("date_time" = "DateTime", "barcode" = "Barcode", "col" = "Col", "cycle" = "Cycle", "exposure time" = "Exposure Time", "filter" = "Filter", 
                  "ps12" = "PS12", "row" = "Row", "temperature" = "Temperature", "timestamp" = "Timestamp", "instrument unit" = "Instrument Unit", "run id" = "Run ID")
TAG_NAMES <- as.vector(unlist(TAG_LIST))
IMAGE_COL <- "Image"
LOADING_DATA <- "Loading data"

get_file_tags <- function(filename) {
  tags <- NULL

  all_tags <- suppressWarnings(ijtiff::read_tags(filename))
  if (!is.null(all_tags) && !is.null(names(all_tags)) && "frame1" %in% names(all_tags)) {
    tags <- all_tags$frame1
    tags <- tags[names(TAG_LIST)]
    names(tags) <- TAG_NAMES
  }
  tags
}

doc_to_data <- function(df, ctx){
  #1. extract files
  
  docId = df$documentId[1]
  doc = ctx$client$fileService$get(docId)
  filename = tempfile()
  writeBin(ctx$client$fileService$download(docId), filename)
  on.exit(unlink(filename))
  
  # unzip if archive
  if(length(grep(".zip", doc$name)) > 0) {
    tmpdir <- tempfile()
    unzip(filename, exdir = tmpdir)
    f.names <- list.files(file.path(list.files(tmpdir, full.names = TRUE), "ImageResults"), full.names = TRUE)
    if(length(f.names) == 0){
      f.names <- list.files(file.path(list.files(tmpdir, full.names = TRUE)), full.names = TRUE)  
    }
  } else {
    f.names <- filename
  }
  
  # read tags
  result <- do.call(rbind, lapply(f.names, FUN = function(filename) {
    tags <- get_file_tags(filename)
    image        <- filename
    names(image) <- IMAGE_COL
    as.data.frame(t(as.data.frame(c(image, unlist(tags)))))
  }))
  
  result %>% 
    mutate(path = "ImageResults") %>% 
    mutate(documentId = docId) %>%
    mutate_at(vars(Col, Cycle, 'Exposure Time', Row, Temperature), .funs = function(x) { as.numeric(as.character(x)) }) %>%
    select(documentId, path, all_of(IMAGE_COL), all_of(TAG_NAMES))
}

getData <- function(session){
  ctx = getCtx(session)
  
  if (!any(ctx$cnames == "documentId")) stop("Column factor documentId is required") 
  
  result <- ctx$cselect() %>%
    doc_to_data(ctx)
  
  return(result)
}
