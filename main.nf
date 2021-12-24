#!/usr/bin/env nextflow

IONICE = 'ionice -c2 -n7'
params.chunks = 1

// Generic data
AUTOSOMAL_REFERENCES = ['hg19': (1..22).collect({it -> 'chr' + it}),
            'hg38': (1..22).collect({it -> 'chr' + it}),
            'rn5': (1..20).collect({it -> 'chr' + it}),
            'rn6': (1..20).collect({it -> 'chr' + it}),
            'mm9': (1..19).collect({it -> 'chr' + it}),
            'mm10': (1..19).collect({it -> 'chr' + it})
]

ORGANISMS = ['hg19': 'human', 
        'hg38': 'human',
        'rn5': 'rat',
        'rn6': 'rat',
        'mm9': 'mouse',
        'mm10': 'mouse']

libraries = params.libraries.keySet()

make_excluded_regions_arg = {
    genome ->
    return params.blacklist[genome].collect({'--excluded-region-file ' + it}).join(' ')
}


is_chimeric = {
    library ->
    return get_genome(library).size() > 1
}


get_bwa_index = {
    genome ->
    params.bwa_index[genome]
}


get_genome = {
    library ->
    params.libraries[library].genome
}


get_tss = {
    genome ->
    params.tss[genome]
}


get_organism = {
    genome ->
    ORGANISMS[genome]
}


get_chrom_sizes = {
    genome ->
    params.chrom_sizes[genome]
}


get_gene_bed = {
    genome ->
    params.gene_bed[genome]
}


library_to_readgroups = {
    library ->
    params.libraries[library].readgroups.keySet()
}


library_and_readgroup_to_fastqs = {
    library, readgroup ->
    params.libraries[library].readgroups[readgroup]
}


trim_in_inserts = []
transform_barcode_in = []
fastqc_in = []
chunk_fastq_in = []
no_chunk_fastq_in = []

for (library in libraries) {
    for (readgroup in library_to_readgroups(library)) {
        fastqs = library_and_readgroup_to_fastqs(library, readgroup)
        first_insert = fastqs['1']
        second_insert = fastqs['2']
        barcode = fastqs['index']
        if (params.chunks > 1) {
            chunk_fastq_in << [library, readgroup, "barcode", file(barcode)]
            chunk_fastq_in << [library, readgroup, "1", file(first_insert)]
            chunk_fastq_in << [library, readgroup, "2", file(second_insert)]
        } else {
            no_chunk_fastq_in << [library, readgroup, "barcode", file(barcode)]
            no_chunk_fastq_in << [library, readgroup, "1", file(first_insert)]
            no_chunk_fastq_in << [library, readgroup, "2", file(second_insert)]
        }
        fastqc_in << [library, readgroup, "1", file(first_insert)]
        fastqc_in << [library, readgroup, "2", file(second_insert)]
        fastqc_in << [library, readgroup, "barcode", file(barcode)]
    }
}


process fastqc {

    publishDir "${params.results}/fastqc/before-trim", mode: 'rellink', overwrite: true
    time '24h'

    input:
    set val(library), val(readgroup), val(read), file(fastq) from Channel.from(fastqc_in)

    output:
    set file(outfile_1), file(outfile_2)

    script:
    outfile_1 = fastq.getName().replaceAll('.fastq.gz', '_fastqc.html')
    outfile_2 = fastq.getName().replaceAll('.fastq.gz', '_fastqc.zip')

    """
    fastqc $fastq
    """

}


process chunk_fastq {

    maxForks 10
    time '24h'

    input:
    set val(library), val(readgroup), val(read), file(fastq) from Channel.from(chunk_fastq_in)

    output:
    set val(library), val(readgroup), val(read), file("*.fastq") into chunked

    when:
    params.chunks > 1

    """
    chunk-fastq.py $fastq ${params.chunks} ${library}___${readgroup}.${read}.
    """

}

inserts = Channel.create()
first_insert = Channel.create()
second_insert = Channel.create()
barcodes = Channel.create()

chunked.transpose().map({it -> [it[0], it[1], it[3].getName().replaceAll(it[0] + "___" + it[1] + "." + it[2] + ".", '').replaceAll('.fastq', ''), it[2], it[3]]}).map({it -> [it[0], it[1] + "___" + it[2], it[3], it[4]]}).mix(Channel.from(no_chunk_fastq_in)).choice(inserts, barcodes) { it -> it[2] == 'barcode' ? 1 : 0 }
inserts.choice(first_insert, second_insert) { it -> it[2] == '1' ? 0 : 1 }

// Trim/reverse complement barcode if necessary. Necessary transformation inferred based on naive comparison of barcode read to barcode whitelist.
process transform_barcode {

    publishDir "${params.results}/transformed-barcodes", mode: 'rellink'
    tag "${library}-${readgroup}"
    memory '10 GB'

    input:
    set val(library), val(readgroup), val(read), file(fastq) from barcodes

    output:
    set val(library), val(readgroup), file("${library}___${readgroup}.transformed-barcode.fastq.gz") into trim_in_barcode
    set val(library), file("${library}___${readgroup}.transformed-barcode.fastq.gz") into make_barcode_corrections_in

    """
    ${IONICE} transform-barcode-maybe-gzip.py --check-first 1000000 $fastq ${params['barcode-whitelist']} | gzip -c > ${library}___${readgroup}.transformed-barcode.fastq.gz
    """

}

trim_in = first_insert.map({it -> [it[0], it[1], it[3]]}).combine(second_insert.map({it -> [it[0], it[1], it[3]]}), by: [0, 1]).combine(trim_in_barcode, by: [0, 1])
make_barcode_corrections_in_chan = make_barcode_corrections_in.groupTuple(sort: true)

process make_barcode_corrections {

    publishDir "${params.results}/corrected-barcodes", mode: 'rellink', overwrite: true
    tag "${library}"
    cpus 3
    memory '10 GB'

    input:
    set val(library), file(barcode_fastq) from make_barcode_corrections_in_chan

    output:
    set val(library), file("${library}.barcode_corrections.txt") into make_barcode_corrections_out_chan

    """
    ${IONICE} correct-barcodes.py --threads 3 ${params['barcode-whitelist']} ${barcode_fastq.join(' ')} > ${library}.barcode_corrections.txt
    """

}


process trim {

    publishDir "${params.results}/trim", mode: 'rellink', overwrite: true
    errorStrategy 'retry'
    maxRetries 1
    time '24h'
    tag "${library}-${readgroup}"

    input:
    set val(library), val(readgroup), file(fastq_1), file(fastq_2), file(barcode) from trim_in

    output:
    set val(library), val(readgroup), file("${library}-${readgroup}.1.trimmed.fastq.gz"), file("${library}-${readgroup}.2.trimmed.fastq.gz") into trim_out_chan

    """
    ${IONICE} cta --append-barcode $barcode $fastq_1 $fastq_2 ${library}-${readgroup}.1.trimmed.fastq.gz ${library}-${readgroup}.2.trimmed.fastq.gz
    """

}


trim_out_chan.into{fastqc_post_trim_in; map_in_chan}
fastqc_post_trim_in = fastqc_post_trim_in.map({it -> [it[0], it[1], ['1', '2'], [it[2], it[3]]]}).transpose()

process fastqc_post_trim {

    publishDir "${params.results}/fastqc/after-trim", mode: 'rellink', overwrite: true
    time '24h'

    input:
    set val(library), val(readgroup), val(read), file(fastq) from fastqc_post_trim_in

    output:
    set file(outfile_1), file(outfile_2)

    script:
    outfile_1 = fastq.getName().replaceAll('.fastq.gz', '_fastqc.html')
    outfile_2 = fastq.getName().replaceAll('.fastq.gz', '_fastqc.zip')

    """
    fastqc $fastq
    """

}

tmp = []
for (library in libraries) {
    for(genome in get_genome(library)){
        tmp << [library, genome]
    }
}

map_in_chan = Channel.from(tmp).combine(map_in_chan, by: 0)

process map {

    memory '50 GB'
    cpus 12
    errorStrategy 'retry'
    maxRetries 1
    time '48h'
    tag "${library}-${readgroup}-${genome}"

    publishDir "${params.results}/bwa", mode: 'rellink', overwrite: true

    input:
    set val(library), val(genome), val(readgroup), file(fastq_1), file(fastq_2) from map_in_chan

    output:
    set val(library), val(readgroup), val(genome), file("${library}-${readgroup}-${genome}.bam") into map_out_chan

    """
    bwa mem -I 200,200,5000 -M -t 12 ${get_bwa_index(genome)} ${fastq_1} ${fastq_2} | samtools sort -m 1g -@ 11 -O bam -T sort_tmp -o ${library}-${readgroup}-${genome}.bam -
    """

}


correct_barcodes_in_bam_in = map_out_chan.combine(make_barcode_corrections_out_chan, by: 0)

process correct_barcodes_in_bam {

    tag "${library}-${readgroup}-${genome}"
    publishDir "${params.results}/bwa-corrected-barcodes", mode: 'rellink', overwrite: true
    memory '75 GB'
    time '24h'

    input:
    set val(library), val(readgroup), val(genome), file(bam), file(corrections) from correct_barcodes_in_bam_in

    output:
    set val(library), val(genome), file("${library}-${readgroup}-${genome}.corrected.bam") into correct_barcodes_in_bam_out

    """
    correct-barcodes-in-bam.py $bam $corrections ${library}-${readgroup}-${genome}.corrected.bam
    """

}


process merge_readgroups {

    time '24h'
    publishDir "${params.results}/merge", mode: 'rellink', overwrite: true

    input:
    set val(library), val(genome), file(bams) from correct_barcodes_in_bam_out.groupTuple(by: [0, 1], sort: true)

    output:
    set val(library), val(genome), file("${library}-${genome}.bam") into merge_out

    """
    samtools merge ${library}-${genome}.bam ${bams.join(' ')}
    """

}


process filter_nuclei_with_low_read_counts {

    cpus 10
    memory '25 GB'

    input:
    set val(library), val(genome), file(bam) from merge_out

    output:
    set val(library), val(genome), file("${library}-${genome}.filtered.bam") into markduplicates_in

    """
    samtools view $bam | perl -pe 's/.*(CB:Z:.*?)\\s+.*/\$1\\n/' | grep CB | perl -pe 's/.*://' | sort --parallel=10 -S 20G | uniq -c > counts.txt
    cat counts.txt | awk '\$1>=${params.low_read_count_threshold}' | perl -pe 's/^\\s+\\d+\\s//' > cb-keep.txt
    samtools view -h -b -D CB:cb-keep.txt $bam > ${library}-${genome}.filtered.bam
    """

}


process mark_duplicates {

    publishDir "${params.results}/mark_duplicates", mode: 'rellink', overwrite: true
    errorStrategy 'retry'
    maxRetries 1
    time '24h'
    memory '50 GB'

    input:
    set val(library), val(genome), file("${library}-${genome}.bam") from markduplicates_in

    output:
    set val(library), val(genome), file("${library}-${genome}.md.bam"), file("${library}-${genome}.md.bam.bai") into prune_in
    set val(library), val(genome), file("${library}-${genome}.md.bam"), file("${library}-${genome}.md.bam.bai") into ataqv_in

    """
    java -Xmx40g -Xms40g -jar \$PICARD_JAR MarkDuplicates TMP_DIR=. I=${library}-${genome}.bam O=${library}-${genome}.md.bam READ_ONE_BARCODE_TAG=CB READ_TWO_BARCODE_TAG=CB ASSUME_SORTED=true MAX_RECORDS_IN_RAM=100000000 METRICS_FILE=${library}-${genome}.metrics VALIDATION_STRINGENCY=LENIENT
    samtools index ${library}-${genome}.md.bam
    """

}


process prune {

    publishDir "${params.results}/prune", mode: 'rellink', overwrite: true
    memory '3 GB'
    time '5h'
    errorStrategy 'retry'
    maxRetries 2

    input:
    set val(library), val(genome), file(md_bam), file(bam_index) from prune_in

    output:
    set val(library), val(genome), file("${library}-${genome}.pruned.bam")

    """
    ${IONICE} samtools view -h -b -f 3 -F 4 -F 8 -F 256 -F 1024 -F 2048 -q 30 $md_bam ${AUTOSOMAL_REFERENCES[genome].join(' ')} > ${library}-${genome}.unsorted.bam
    samtools sort -m 2G -o ${library}-${genome}.pruned.bam -T bam-sort -O BAM ${library}-${genome}.unsorted.bam
    """

}


process ataqv {

    publishDir "${params.results}/ataqv", mode: 'rellink', overwrite: true
    errorStrategy 'retry'
    maxRetries 1
    memory { 50.GB * task.attempt }
    time '10h'

    input:
    set val(library), val(genome), file(md_bam), file(bam_index) from ataqv_in

    output:
    set file("${library}-${genome}.ataqv.json.gz"), file("${library}-${genome}.ataqv.out")

    """
    ${IONICE} ataqv --name ${library}-${genome} --ignore-read-groups --nucleus-barcode-tag CB --metrics-file ${library}-${genome}.ataqv.json.gz --tss-file ${get_tss(genome)} ${make_excluded_regions_arg(genome)} ${get_organism(genome)} $md_bam > ${library}-${genome}.ataqv.out
    """

}
