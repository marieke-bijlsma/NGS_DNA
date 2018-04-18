#MOLGENIS walltime=05:59:00 mem=6gb ppn=10
#string logsDir
#string groupname
#string project
#string caddAnnotationVcf
#string toCADD
#string fromCADD
#string projectBatchGenotypedVariantCalls
#string projectBatchGenotypedAnnotatedVariantCalls
#string indexFile
#string htsLibVersion
#string vcfAnnoVersion
#string bcfToolsVersion
#string fromCADDMerged
#string vcfAnnoConf
#string caddVersion
#string exacAnnotation
#string gonlAnnotation
#string gnomADGenomesAnnotation
#string gnomADExomesAnnotation
#string capturingKit
#string vcfAnnoGnomadGenomesConf
#string batchID
#string vcfAnnoCustomConfLua
#string clinvarAnnotation

ml ${vcfAnnoVersion}
ml ${htsLibVersion}
ml ${bcfToolsVersion}
ml ${caddVersion}

makeTmpDir "${projectBatchGenotypedAnnotatedVariantCalls}"
tmpProjectBatchGenotypedAnnotatedVariantCalls="${MC_tmpFile}"

bedfile=$(basename "${capturingKit}")

if [ -f ${projectBatchGenotypedVariantCalls} ]
then 

	echo "create file toCADD"
	##create file toCADD (split alternative alleles per line)
	bcftools norm -f "${indexFile}" -m -any "${projectBatchGenotypedVariantCalls}" | awk '{if (!/^#/){if (length($4) > 1 || length($5) > 1){print $1"\t"$2"\t"$3"\t"$4"\t"$5}}}' | bgzip -c > "${toCADD}.gz"

	echo "starting to get CADD annotations locally for ${toCADD}.gz"
	score.sh "${toCADD}.gz" "${fromCADD}"

	echo "convert fromCADD tsv file to fromCADD vcf"
	##convert tsv to vcf
	(echo -e '##fileformat=VCFv4.1\n##INFO=<ID=raw,Number=A,Type=Float,Description="raw cadd score">\n##INFO=<ID=phred,Number=A,Type=Float,Description="phred-scaled cadd score">\n##CADDCOMMENT=<ID=comment,comment="CADD v1.3 (c) University of Washington and Hudson-Alpha Institute for Biotechnology 2013-2015. All rights reserved.">\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO' && gzip -dc ${fromCADD}\
	| awk '{if(NR>2){ printf $1"\t"$2"\t.\t"$3"\t"$4"\t1\tPASS\traw="; printf "%0.1f;",$5 ;printf "phred=";printf "%0.1f\n",$6}}') | bgzip -c > "${fromCADD}.vcf.gz"

	tabix -f -p vcf "${fromCADD}.vcf.gz"
	##merge the alternative alleles back in one vcf line
	echo "merging the alternative alleles back in one vcf line .. "
	bcftools norm -f "${indexFile}" -m +any "${fromCADD}.vcf.gz" > "${fromCADDMerged}"

	echo "bgzipping + indexing ${fromCADDMerged}"
	bgzip -c "${fromCADDMerged}" > "${fromCADDMerged}.gz"
	tabix -f -p vcf "${fromCADDMerged}.gz"


	## Prepare gnomAD config 
	rm -f "${vcfAnnoGnomadGenomesConf}"
	if [ "${bedfile}" == *"Exoom"* ]
	then
		echo -e "\n[[annotation]]\nfile=\"${gnomADGenomesAnnotation}/gnomad.genomes.r2.0.1.sites.${batchID}.vcf.gz\"\nfields=[\"AF\"]\nnames=[\"gnomAD_AF\"]\nops=[\"self\"]" >> "${vcfAnnoGnomadGenomesConf}"
	else
		for i in {1..22}
		do
			echo -e "\n[[annotation]]\nfile=\"${gnomADGenomesAnnotation}/gnomad.genomes.r2.0.1.sites.${i}.vcf.gz\"\nfields=[\"AF\"]\nnames=[\"gnomAD_AF\"]\nops=[\"self\"]" >> "${vcfAnnoGnomadGenomesConf}"
		done
	fi
	## write first part of conf file
	cat > "${vcfAnnoConf}" << HERE
[[annotation]]
file="${fromCADDMerged}.gz"
fields=["phred", "raw"]
names=["CADD_SCALED","CADD"]
ops=["self","self"]

[[annotation]]
file="${caddAnnotationVcf}"
fields=["phred", "raw"]
names=["CADD_SCALED","CADD"]
ops=["self","self"]

[[annotation]]
file="${exacAnnotation}"
fields=["AF","AC_Het","AC_Hom"]
names=["EXAC_AF","EXAC_AC_HET","EXAC_AC_HOM"]
ops=["self","self","self"]

[[annotation]]
file="${gonlAnnotation}/gonl.chrCombined.snps_indels.r5.vcf.gz"
fields=["AC","AN", "GTC"]
names=["GoNL_AC","GoNL_AN","GoNL_GTC"]
ops=["self","self","self"]

[[annotation]]
file="${gonlAnnotation}/gonl.chrX.release4.gtc.vcf.gz"
fields=["AC","AN", "GTC"]
names=["GoNL_AC","GoNL_AN","GoNL_GTC"]
ops=["self","self","self"]

[[annotation]]
file="${gnomADExomesAnnotation}/gnomad.exomes.r2.0.1.sites.vcf.gz"
fields=["Hom","Het", "AN","AF_POPMAX"]
names=["gnomAD_Hom","gnomAD_Het","gnomAD_AN","gnomAD_AF_MAX"]
ops=["self","self","self","self"]

[[annotation]]
file="${clinvarAnnotation}"
fields=["CLNDN","CLNDISDB","CLNHGVS","CLNSIG"]
names=["clinvar_dn","clinvar_isdb","clinvar_hgvs","clinvar_sig"]
ops=["self","self","self","self"]

HERE

## Adding gnomAD 
cat "${vcfAnnoGnomadGenomesConf}" >> "${vcfAnnoConf}"

#
## make custom .lua for calculating hom and het frequency
#
cat > "${vcfAnnoCustomConfLua}" << HERE

function calculate_gnomAD_AC(ind)
if(ind[1] == 0) then return "0" end
    return (ind[1] * 2)
end
--clinvar check if pathogenic is common variant in gnomAD
CLINVAR_SIG = {}
CLINVAR_SIG["0"] = 'uncertain'
CLINVAR_SIG["1"] = 'not-provided'
CLINVAR_SIG["2"] = 'benign'
CLINVAR_SIG["3"] = 'likely-benign'
CLINVAR_SIG["4"] = 'likely-pathogenic'
CLINVAR_SIG["5"] = 'pathogenic'
CLINVAR_SIG["6"] = 'drug-response'
CLINVAR_SIG["7"] = 'histocompatibility'
CLINVAR_SIG["255"] = 'other'
CLINVAR_SIG["."] = '.'

function contains(str, tok)
	return string.find(str, tok) ~= nil
end

function intotbl(ud)
	local tbl = {}
	for i=1,#ud do
		tbl[i] = ud[i]
	end
	return tbl
end

function clinvar_sig(vals)
    local t = type(vals)
    -- just a single-value
    if(t == "string" or t == "number") and not contains(vals, "|") then
        return CLINVAR_SIG[vals]
    elseif t ~= "table" then
		if not contains(t, "userdata") then
			vals = {vals}
		else
			vals = intotbl(vals)
		end
    end
    local ret = {}
    for i=1,#vals do
        if not contains(vals[i], "|") then
            ret[#ret+1] = CLINVAR_SIG[vals[i]]
        else
            local invals = vals[i]:split("|")
            local inret = {}
            for j=1,#invals do
                inret[#inret+1] = CLINVAR_SIG[invals[j]]
            end
            ret[#ret+1] = join(inret, "|")
        end
    end
    return join(ret, ",")
end

join = table.concat

function check_clinvar_aaf(clinvar_sig, max_aaf_all, aaf_cutoff)
    -- didn't find an aaf for this so can't be common
    if max_aaf_all == nil or clinvar_sig == nil then
        return false
    end
    if type(clinvar_sig) ~= "string" then
        clinvar_sig = join(clinvar_sig, ",")
    end
    if false == contains(clinvar_sig, "pathogenic") then
        return false
    end
    if type(max_aaf_all) ~= "table" then
        return max_aaf_all > aaf_cutoff
    end
    for i, aaf in pairs(max_aaf_all) do
        if aaf > aaf_cutoff then
            return true
        end
    end
    return false
end

HERE

cat >> "${vcfAnnoConf}" << HERE

## Calculating GoNL AF, gnomAD_HOM_AC
[[postannotation]]
fields=["GoNL_AC", "GoNL_AN"]
name="GoNL_AF"
op="div2"
type="Float"

[[postannotation]]
fields=["gnomAD_Hom"]
name="gnomAD_AN_Hom"
op="lua:calculate_gnomAD_AC(gnomAD_Hom)"
type="Integer"

[[postannotation]]
fields=["gnomAD_Het"]
name="gnomAD_AN_Het"
op="lua:calculate_gnomAD_AC(gnomAD_Het)"
type="Integer"

[[postannotation]]
fields=["gnomAD_AN_Hom", "gnomAD_AN"]
name="gnomAD_AF_Hom"
op="div2"
type="Float"

[[postannotation]]
fields=["gnomAD_AN_Het", "gnomAD_AN"]
name="gnomAD_AF_Het"
op="div2"
type="Float"

[[postannotation]]
fields=["clinvar_sig", "gnomAD_AF_MAX"]
op="lua:check_clinvar_aaf(clinvar_sig, gnomAD_AF_MAX, 0.005)"
name="common_pathogenic"
type="Flag"

HERE


	echo "starting to annotate with vcfanno"
	vcfanno_linux64 -lua "${vcfAnnoCustomConfLua}" "${vcfAnnoConf}" "${projectBatchGenotypedVariantCalls}" > "${tmpProjectBatchGenotypedAnnotatedVariantCalls}"

	mv "${tmpProjectBatchGenotypedAnnotatedVariantCalls}" "${projectBatchGenotypedAnnotatedVariantCalls}"
	echo "mv ${tmpProjectBatchGenotypedAnnotatedVariantCalls} ${projectBatchGenotypedAnnotatedVariantCalls}" 
else
	echo "${projectBatchGenotypedVariantCalls} does not exist, skipped"
fi
