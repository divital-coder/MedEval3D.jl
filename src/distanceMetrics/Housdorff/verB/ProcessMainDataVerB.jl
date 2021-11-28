module ProcessMainDataVerB
using CUDA, Logging,Main.CUDAGpuUtils,Main.WorkQueueUtils, Logging,StaticArrays,Main.MetaDataUtils, Main.IterationUtils, Main.ReductionUtils, Main.CUDAAtomicUtils,Main.MetaDataUtils, Main.ResultListUtils
export @dilatateHelper,getDir,@validateData, @executeDataIterWithPadding, @loadMainValues,setNextBlockAsIsToBeActivated,@paddingProcessCombined,calculateLoopsIter,@processMaskData, @paddingIter,@processPadding

# """
# we need to establish is the block full after dilatation step 
# """
# macro establishIsFull()
#     return esc(quote
#     @redWitAct(offsetIter,shmemSum,  isMaskFull,& )
#     sync_threads()
#     #now if it evaluated to 1 we should save it to metadata 
#     @ifXY 1 1 setBlockAsFull(metaData,linIndex, isGoldPass)
# end)
# end#establishIsFull

                
"""
 validates data is of our intrest               
"""                
macro validateData(isGold,xMeta,yMeta,zMeta,iterNumb,mainArr,refArr,targetArr)
    return esc(quote
   #first we will load data from target arr so we can be sure that we are not ovewriting sth already written by diffrent thread block
   locArr = @inbounds($targetArr[($xMeta-1)*dataBdim[1]+ threadIdxX(),($yMeta-1)*dataBdim[2]+ threadIdxY(),$zMeta])
   # here we are anaylyzing only main part of the  data block paddings will be analyzed separately
   @unroll for bitIter in 1:32
    #    resShemVal = isBit1AtPos(@inbounds(resShmemblockData[threadIdxX(),threadIdxY()]), bitIter)
    #    inTarget = isBit1AtPos(locArr, bitIter)
    #    #later usefull to establish is mask full
    #    isMaskFull= resShemVal & isMaskFull
    #    #so we have voxel that was not yet covered earlier, is covered now and is in refrence arr - so one where we establish is sth covered 
    #    if(resShemVal && !inTarget)
    #        # we need reference array value to check weather we had covered anything new from other arrayin this iteration
    #         # if($refArr[($xMeta-1)*dataBdim[1]+ threadIdxX(),($yMeta-1)*dataBdim[2]+ threadIdxY(),($zMeta-1)*dataBdim[3]+ bitIter  ] == numberToLooFor)
    #         #     @addResult(metaData
    #         #     ,$xMeta,$yMeta ,$zMeta,resList
    #         #     ,(($xMeta-1)*dataBdim[1]+ threadIdxX())
    #         #     ,(($yMeta-1)*dataBdim[2]+ threadIdxY())
    #         #     ,($zMeta-1)*dataBdim[3]+ bitIter
    #         #     ,getDir(sourceShmem,xpos,ypos,zpos,dataBdim)
    #         #     ,$iterNumb
    #         #     ,getIndexOfQueue(threadIdxX(),threadIdxY(),bitIter,dataBdim,(1-$isGold))
    #         #     ,metaDataDims
    #         #     ,mainArrDims
    #         #     ,$isGold)
    #         # end
    #    end  
   end 
   
    end)


    
 end  #validateData                  


"""
   loads main values from analyzed array into shared memory and to locArr - which live in registers   
   it all works under the assumption that x and y dimension of the thread block and data block is the same           
"""                
                
macro loadMainValues(mainArr,xMeta,yMeta,zMeta)
    return esc(quote
  #by construction one thread will neeed to load just one integer into its registers and to resShmemblockData
  locArr = $mainArr[($xMeta-1)*dataBdim[1]+ threadIdxX(),($yMeta-1)*dataBdim[2]+ threadIdxY(),$zMeta]
  shmemblockData[threadIdxX(),threadIdxY()] = locArr
  #now immidiately we can go with dilatation up and down and save it to res shmem we are not modyfing  locArr
  resShmemblockData[threadIdxX(),threadIdxY()]=@bitDilatate(locArr)
  # now if we have values in first or last bit we need to modify appropriate spots in the shmemPaddings
  shmemPaddings[threadIdxX(),threadIdxY(),1]=isBit1AtPos(locArr,1)#top
  shmemPaddings[threadIdxX(),threadIdxY(),2]=isBit1AtPos(locArr,dataBdim[3])#bottom
  #now we will  do left - right dilatations howvewer we must be sure that we checked boundary conditions 
  
  #left
  @dilatateHelper((threadIdxX()==1), 3,bitPos,threadIdxY(),(-1), (0))

 #right
 @dilatateHelper((threadIdxX()==dataBdim[1]), 4,bitPos,threadIdxY(),(1), (0))

#  #posterior
 @dilatateHelper((threadIdxY()==1), 5,threadIdxX(), bitPos,(0), (-1))

#   #anterior 
@dilatateHelper((threadIdxY()==dataBdim[2]), 6,threadIdxX(), bitPos,(0), (1))

end) #quote              
end #loadMainValues


"""
helper macro to iterate over the threads and given their position - checking edge cases do appropriate dilatations ...
    predicate - indicates what we consider border case here 
    paddingPos= integer marking which padding we are currently talking about (top? bottom? anterior ? ...)
    padingVariedA, padingVariedB - eithr bitPos threadid X or Y depending what will be changing in this case
    
    normalXChange, normalYchange - indicating which wntries we are intrested in if we are not at the boundary so how much to add to x and y thread position

"""
macro dilatateHelper(predicate, paddingPos, padingVariedA, padingVariedB,normalXChange, normalYchange)
    return esc(quote
        if($predicate)
            for bitPos in 1:32
                shmemPaddings[$padingVariedA,$padingVariedB,$paddingPos]=isBit1AtPos(locArr,bitPos)
            end
        else
          resShmemblockData[threadIdxX(),threadIdxY()]= @bitPassOnes(resShmemblockData[threadIdxX(),threadIdxY()],shmemblockData[threadIdxX()+($normalXChange),threadIdxY()+$(normalYchange)]   )
        end 
    end)#quote
end




"""
now in case we  want later to establish source of the data - would like to find the true distances  not taking the assumption of isometric voxels
we need to store now data from what direction given voxel was activated what will later gratly simplify the task of finding the true distance 
we will record first found true voxel from each of six directions 
                 top 6 
                bottom 5  
                left 2
                right 1 
                anterior 3
                posterior 4
"""
function getDir(sourceShmem,xpos,ypos,zpos,dataBdim)::UInt8
    return if((bitIter-1)>0 && isBit1AtPos(@inbounds(shmemblockData[threadIdxX(),threadIdxY()]), bitIter-1) ) 
                6
            elseif(((bitIter)<dataBdim[3]) && isBit1AtPos(@inbounds(shmemblockData[threadIdxX(),threadIdxY()]), bitIter+1) ) 
                5
            elseif((threadIdxX()-1>0) && isBit1AtPos(@inbounds(shmemblockData[threadIdxX()-1,threadIdxY()]), bitIter) )
                2
            elseif((threadIdxX()<dataBdim[1]) && isBit1AtPos(@inbounds(shmemblockData[threadIdxX()+1,threadIdxY()]), bitIter) )
                1
            elseif((threadIdxY()-1>0) && isBit1AtPos(@inbounds(shmemblockData[threadIdxX(),threadIdxY()-1]), bitIter) )
                3
            else 
                4            
            end
end#getDir

"""
collects all needed functions to analyze given data blocks 
- so it loads data from main array (what is main and reference array depends on is it a gold pass or other pass)
then 
"""
macro executeDataIterWithPadding(mainArrDims, inBlockLoopXZIterWithPadding
    ,mainArr,refArr,targetArr,xMeta,yMeta,zMeta,isGold,iterNumb)
    return esc(quote
  ############## upload data
  @ifY 1 if(threadIdxX()<15) areToBeValidated[threadIdxX()] =metaData[($xMeta+1),($yMeta+1),($zMeta+1),(getIsToBeAnalyzedNumb() +threadIdxX())]  end 
  @loadMainValues($mainArr,$xMeta,$yMeta,$zMeta)                                       
  sync_threads()
  ########## check data aprat from padding
  #can be skipped if we have the block with already all results analyzed 
  if(areToBeValidated[14-$isGold])
      @validateData($mainArrDims, $inBlockLoopX,$inBlockLoopY,$inBlockLoopZ,$mainArr,$refArr,$xMeta,$yMeta,$zMeta,$isGold,$iterNumb) 
  end                  
  #processing padding
  @processPadding($isGold,$xMeta,$yMeta,$zMeta,$iterNumb,$mainArr,$refArr)
  #now in case to establish is the block full we need to reduce the isMaskFull information
  


  #wheather validation took place or not we need to save resShmemblockData to target array  
  $targetArr[($xMeta-1)*dataBdim[1]+ threadIdxX(),($yMeta-1)*dataBdim[2]+ threadIdxY(),$zMeta]= resShmemblockData[threadIdxX(),threadIdxY()]
  #now we need to establish are we full here
  isMaskFull =syncThreadsAnd(isMaskFull)
  @ifXY 1 1 if(isMaskFull) metaData[$xMeta,$yMeta,$zMeta,getFullInSegmNumb()-$isGold]=1  end
  sync_warp()# so is mask full on first thread would not be overwritten


end)
end#executeDataIterWithPadding








"""
Iteration will start only if the associated  isToBeValidated entry in isToBevalidated data is true  (which we got from metadata and indicates is there anything of our intrest in validating given padding ...)

We should also supply loopX and loopY constants that are constant kernel wide  and can be precalculated 
maxXdim, maxYdim - provides maximal dimensions in x and y direction off padding plane (not of the whole image)
provides iteration over padding - we have 3 diffrent planes to analyze - and third dimensions will be rigidly set as constant and equal either to 1 or max of this simension
we also need supplied direction from which the dilatation was done (dir)           top 6          bottom 5     left 2       right 1      anterior 3      posterior 4
as tis is just basis that will be specialized for each padding we need also some expressions
    a,b.c - variables used to  getting value  from the padding and reurning true or false, it will operate using calculated x and y  (so we need to insert x symbol y symbol and constant number as a,b,c in coreect order) in diffrent psitions depending on the plane
    dataBdim - dimensionality of a data block 
//markNexBlockAsToBeActivated - whole expression that using given xMeta,yMeta,zMeta and the position of padding given we are in range will mark block as toBeActivated
    setMainArrToTrue - sets given spot in the main array to true - based on meta data and calculated inside loop x,y position
x,y offset and add probably can be left as defaoult
resShmem - shared memoy 3 dimensional boolean array
isAnyPositive - shared memory value indicating is anything was evaluated as true in the padding as true 
xMetaChange,yMetaChange,zMetaChange - indicates how the meata coordinates (coordinates of metadata block of intrest will change)
isToBeValidated - indicates weather we should validate data from dilatation or just write the dilatation to global memory
mainArr - main array which we modify during dilatations
refArr - array we will check weather dilatation had covered any new intresting voxel
resList - list with result
dir - direction from which we performed dilatation
queueNumber - what fp or fn queue we are intrested in modyfing now 
,xMeta,yMeta,zMeta - metadata x y z coordinates
"""
macro paddingIter(loopX,loopY,maxXdim, maxYdim,ex)
    mainExp = generalizedItermultiDim(
    arrDims=:()
    ,loopXdim=loopX
    ,loopYdim=loopY
    ,yCheck = :(y <=$maxYdim)
    ,xCheck = :(x <=$maxXdim )
    ,is3d = false
    , ex = ex)
      return esc(:( $mainExp))
end
   

"""
combines above function to make it more convinient to call
"""
macro paddingProcessCombined(loopX,loopY,maxXdim, maxYdim,a,b,c , xMetaChange,yMetaChange,zMetaChange, mainArr,refArr, dir,iterNumb,queueNumber,xMeta,yMeta,zMeta,isGold)
 #   function paddingProcessCombined(loopX,loopY,maxXdim, maxYdim,a,b,c , xMetaChange,yMetaChange,zMetaChange, mainArr,refArr, dir,iterNumb,queueNumber,xMeta,yMeta,zMeta,isGold,resShmem,dataBdim,metaData,resList,resListIndicies,maxResListIndex,metaDataDims )
    return esc(quote
    @paddingIter($loopX,$loopY,$maxXdim, $maxYdim, begin
        if(resShmem[$a,$b,$c])
                #CUDA.@cuprint "meta bounds checks $($xMeta+$xMetaChange>0) $($xMeta+$xMetaChange<=metaDataDims[1]) $($yMeta+$yMetaChange>0) $($yMeta+$yMetaChange<=metaDataDims[2])  $($zMeta+$zMetaChange>0) $($zMeta+$zMetaChange<=metaDataDims[3]) \n "
                @inbounds isAnythingInPadding[$dir]=true# indicating that we have sth positive in this padding 
                #below we do actual dilatation
                if((($xMeta+1)+($xMetaChange)>0) && (($xMeta+1)+($xMetaChange))<=(metaDataDims[1])  && (($yMeta+1)+($yMetaChange)>0) && (($yMeta+1)+($yMetaChange)<=metaDataDims[2]) && (($zMeta+1)+($zMetaChange))>0 && (($zMeta+1)+($zMetaChange))<=metaDataDims[3]  )
                    @inbounds $mainArr[($xMeta)*dataBdim[1]+$a,($yMeta)*dataBdim[2]+$b,($zMeta)*dataBdim[3]+$c]=true
                    #checking is it marked as to be validates
                    if(areToBeValidated[$queueNumber])
                        #if we have true in reference array in analyzed spot
                        if($refArr[($xMeta)*dataBdim[1]+$a,($yMeta)*dataBdim[2]+$b,($zMeta)*dataBdim[3]+$c])
                            # aa = $a
                            # bb= $b
                            # cc = $c
                            # if($queueNumber==1)
                            #     CUDA.@cuprint "a $(aa) b $(bb) c $(cc) \n"    
                            # end        

                            #adding the result to the result list at correct spot - using metadata taken from metadata
                            @addResult(metaData
                            ,$xMeta+($xMetaChange)
                            ,$yMeta+($yMetaChange)
                            ,$zMeta+($zMetaChange)
                            ,resList
                            ,resListIndicies
                            ,(($xMeta)*dataBdim[1]+$a)
                            ,(($yMeta)*dataBdim[2]+$b)
                            ,(($zMeta)*dataBdim[3]+$c)
                            ,$dir
                            ,$iterNumb
                            ,$queueNumber
                            ,metaDataDims
                            ,mainArrDims
                            ,$isGold    )
                        end
                    end
                end
            end


    end)
    end)#quote
end


"""
In case we have any true in padding we need to set the next block as to be activated 
yet we need also to test wheather next block in this direction actually exists so we check metadata dimensions
metaData - multidim array with metadata about data blocks
isToBeActivated - boolean taken from res shmem indicating weather there was any  true in related direction
xMeta,yMeta,zMeta - current metadata spot 
isGold - indicating wheather we are in gold or other pass
xMetaChange,yMetaChange,zMetaChange - points in which direction we should go in analyzis of metadata - how to change current metaData 
metaDataDims - dimensions of metadata

"""
function setNextBlockAsIsToBeActivated(isToBeActivated::Bool,xMetaChange,yMetaChange,zMetaChange,xMeta,yMeta,zMeta,isGold,  metaData, metaDataDims)
   if(isToBeActivated && (xMeta+1)+xMetaChange<=metaDataDims[1]  && (yMeta+1)+yMetaChange>0 && (yMeta+1)+yMetaChange<=metaDataDims[2] && (zMeta+1)+zMetaChange>0 && (zMeta+1)+zMetaChange<=metaDataDims[3]) 
    metaData[(xMeta+1)+xMetaChange,(yMeta+1)+yMetaChange,(zMeta+1)+zMetaChange,getIsToBeActivatedInSegmNumb()-isGold  ]=1 
    end
end

"""
executes paddingProcessCombined over all paddings 
"""
macro processPadding(isGold,xMeta,yMeta,zMeta,iterNumb,mainArr,refArr)
    return esc(quote
         
    
         # #process top padding
        @paddingProcessCombined(loopAZFixed,loopBZfixed,dataBdim[1], dataBdim[2], x,y,1 ,0,0,-1,  $mainArr,$refArr,5,$iterNumb, 12-$isGold,$xMeta,$yMeta,$zMeta,$isGold)
       
        # #process bottom padding
        @paddingProcessCombined(loopAZFixed,loopBZfixed,dataBdim[1],dataBdim[2],x,y,dataBdim[3]+2,0,0,1,$mainArr,$refArr,6,$iterNumb,10-$isGold,$xMeta,$yMeta,$zMeta,$isGold)
        # 
    #process left padding
         @paddingProcessCombined(loopAXFixed,loopBXfixed,dataBdim[2], dataBdim[3],1,x,y , -1,0,0,  $mainArr,$refArr,1,$iterNumb, 4-$isGold,$xMeta,$yMeta,$zMeta,$isGold )
       
       
         # #process rigth padding
        @paddingProcessCombined(loopAXFixed,loopBXfixed,dataBdim[2], dataBdim[3], dataBdim[1]+2,x,y , 1,0,0,  $mainArr,$refArr,2,$iterNumb, 2-$isGold,$xMeta,$yMeta,$zMeta,$isGold)
       #process anterior padding
        @paddingProcessCombined(loopAYFixed,loopBYfixed,dataBdim[1], dataBdim[3], x,dataBdim[2]+2,y , 0,1,0,  $mainArr,$refArr,4,$iterNumb, 6-$isGold,$xMeta,$yMeta,$zMeta,$isGold)

        #process posterior padding
        @paddingProcessCombined(loopAYFixed,loopBYfixed,dataBdim[1], dataBdim[3], x,1,y , 0,-1,0,  $mainArr,$refArr,3,$iterNumb, 8-$isGold,$xMeta,$yMeta,$zMeta,$isGold)
        #checking res  shmem (we used part that is unused in  dilatation step) 
        
        sync_threads()
        
        @ifXY 1 1 setNextBlockAsIsToBeActivated(isAnythingInPadding[1] ,-1,0,0,$xMeta,$yMeta,$zMeta,$isGold,  metaData, metaDataDims)
        @ifXY 2 1 setNextBlockAsIsToBeActivated(isAnythingInPadding[2] ,1,0,0,$xMeta,$yMeta,$zMeta,$isGold,  metaData, metaDataDims)
        @ifXY 3 1 setNextBlockAsIsToBeActivated(isAnythingInPadding[3] ,0,-1,0,$xMeta,$yMeta,$zMeta,$isGold,  metaData, metaDataDims)
        @ifXY 4 1 setNextBlockAsIsToBeActivated(isAnythingInPadding[4] ,0,1,0,$xMeta,$yMeta,$zMeta,$isGold,  metaData, metaDataDims)
        @ifXY 5 1 setNextBlockAsIsToBeActivated(isAnythingInPadding[5] ,0,0,-1,$xMeta,$yMeta,$zMeta,$isGold,  metaData, metaDataDims)
        @ifXY 6 1 setNextBlockAsIsToBeActivated(isAnythingInPadding[6] , 0,0,1,$xMeta,$yMeta,$zMeta,$isGold,  metaData, metaDataDims)

    end)

end#processPadding
           



end#ProcessMainDataVerB






# """
# we are processing padding 
# """
# macro processPadding()
#     return esc(quote
#     #so here we utilize iter3 with 1 dim fixed 
#     @unroll for  dim in 1:3, numb in [1,34]              
#         @iter3dFixed dim numb if( isPaddingToBeAnalyzed(resShmem,dim,numb ))
#                 if(val)#if value in padding associated with this spot is true
#                     # setting value in global memory
#                     @inbounds  analyzedArr[x,y,z]= true
#                     # if we are here we have some voxel that was false in a primary mask and is becoming now true - if it is additionaly true in reference we need to add it to result
#                     resShmem[1,1,1]=true
#                     if(@inbounds referenceArray[x,y,z])
#                         appendResultPadding(metaData, linIndex, x,y,z,iterationnumber, dim,numb)
#                 end#if
#                 #we need to check is next block in given direction exists
#                 if(isNextBlockExists(metaData,dim, numb ,linIter, isPassGold, maxX,maxY,maxZ))
#                     if(resShmem[1,1,1])
#                         @ifXY 1 1 setAsToBeActivated(metaData,linIndex,isPassGold)
#                     end    
#                 end # if isNextBlockExists       
#             end # if isPaddingToBeAnalyzed   
#         end#iter3dFixed       
#     end#for
# end)
# end





# """
# Help to establish should we validate the voxel - so if ok add to result set, update the main array etc
#   in case we have some true in padding
#   generally we need just to get idea if
#     we already had true in this very spot - if so we ignore it
#     can this spot be reached by other voxels from the block we are reaching into - in other words padding is analyzing the same data as other block is analyzing in its main part
#       hence if the block that is doing it in main part will reach this spot on its own we will ignore value from padding 

#   in order to reduce sears direction by 1 it would be also beneficial to know from where we had came - from what direction the block we are spilled into padding 
# """
# function isPaddingValToBeValidated(dir,analyzedArr, x,y,z )::Bool
     
# if(dir!=5)  if( @inbounds resShmem[threadIdxX(),threadIdxY(),zIter-1]) return false  end end #up
# if(dir!=6)  if( @inbounds  resShmem[threadIdxX(),threadIdxY(),zIter+1]) return false  end  end #down
    
# if(dir!=1)   if( @inbounds  resShmem[threadIdxX()-1,threadIdxY(),zIter]) return false  end  end #left
# if(dir!=2)   if( @inbounds   resShmem[threadIdxX()+1,threadIdxY(),zIter]) return false  end end  #right

# if(dir!=4)   if(  @inbounds  resShmem[threadIdxX(),threadIdxY()+1,zIter]) return false  end  end #front
# if(dir!=3)   if( @inbounds  resShmem[threadIdxX(),threadIdxY()-1,zIter]) return false  end end  #back
#   #will return true only in case there is nothing around 
#   return true
# end
