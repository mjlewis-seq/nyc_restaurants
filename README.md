# HazardRx

## Overview

HazardRx is an AI-leveraging tool that allows restaurant owners to describe common kitchen issues and receive recommendations for corrective action. With HazardRx, culinary entrepreneurs can proactively tackle problems that could lower health inspection grades. 

This project was completed as Team NameOfTeam's entry to the [AI Data Science Hackathon](https://aiwsnyc.org/hackathon) as part of [The 2nd AI Workshop New York City](https://aiwsnyc.org/) in July 2026.

### Authors

- [Tommy Deth](https://github.com/phantomas34)
- [Lillie Hutchings](https://github.com/lilliehutchings)
- [Mikhaela Lewis](https://github.com/mjlewis-seq)

## Build

- Backend -> R Shiny
- Chat Assistant -> Claude Sonnet 4.6
- RAG Pipeline -> RAGFlow
- RAG Embedding Model -> Voyage 4 Large

## Features

Users can:

- enter text descriptions of potential issues.
- upload images of potential issues.
- review likely New York City Health Code (NYCHC) violation, severity level.
- receive recommendations for corrective actions via text response and Yelp search.

## Installation

```bash
git clone https://github.com/mjlewis-seq/hazardrx # Clone the repository
cd hazardrx # Navigate to the project root
```

## Usage

```r
library(shiny)
runApp("shiny_app/app.R")
```

## License

This project currently has no license. All rights are reserved by the authors. 
If you're interested in using or building on this work, please reach out.

